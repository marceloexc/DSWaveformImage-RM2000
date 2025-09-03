//
// see
// * http://www.davidstarke.com/2015/04/waveforms.html
// * http://stackoverflow.com/questions/28626914
// for very good explanations of the asset reading and processing path
//
// FFT done using: https://github.com/jscalo/tempi-fft
//

import Foundation
import Accelerate
import AVFoundation

private actor WaveformProcessingActor {
    private var currentProcessingCount = 0
    private let maxConcurrentOperations = 3 // Only allow 1 at a time on macOS 26
    private var waitingQueue: [CheckedContinuation<Void, Never>] = []
    
    func requestProcessingSlot() async {
        if currentProcessingCount >= maxConcurrentOperations {
            await withCheckedContinuation { continuation in
                waitingQueue.append(continuation)
            }
        }
        currentProcessingCount += 1
    }
    
    func releaseProcessingSlot() {
        currentProcessingCount = max(0, currentProcessingCount - 1)
        
        // Wake up next waiting request
        if !waitingQueue.isEmpty && currentProcessingCount < maxConcurrentOperations {
            let continuation = waitingQueue.removeFirst()
            continuation.resume()
        }
    }
}

private let processingActor = WaveformProcessingActor()

struct WaveformAnalysis {
    let amplitudes: [Float]
    let fft: [TempiFFT]?
}

/// Calculates the waveform of the initialized asset URL.
public struct WaveformAnalyzer: Sendable {
    public enum AnalyzeError: Error { case generic, userError, emptyTracks, readerError(AVAssetReader.Status) }

    /// Everything below this noise floor cutoff will be clipped and interpreted as silence. Default is `-50.0`.
    public var noiseFloorDecibelCutoff: Float = -50.0

    public init() {}

    // 2. In WaveformAnalyzer.swift - Add debug logging to the samples function
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> [Float] {
        // Request a processing slot to limit concurrency
        await processingActor.requestProcessingSlot()
        
        do {
            let result = try await Task(priority: taskPriority(qos: qos)) {
                let audioAsset = AVURLAsset(url: audioAssetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let assetReader = try AVAssetReader(asset: audioAsset)
                guard let assetTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                    throw AnalyzeError.emptyTracks
                }
                let result = try await waveformSamples(track: assetTrack, reader: assetReader, count: count, fftBands: nil).amplitudes
                return result
            }.value
            
            await processingActor.releaseProcessingSlot()
            return result
        } catch {
            await processingActor.releaseProcessingSlot()
            throw error
        }
    }


    /// Calculates the amplitude envelope of the initialized audio asset URL, downsampled to the required `count` amount of samples.
    /// - Parameter fromAudioAt: local filesystem URL of the audio file to process.
    /// - Parameter count: amount of samples to be calculated. Downsamples.
    /// - Parameter qos: QoS of the DispatchQueue the calculations are performed (and returned) on.
    /// - Parameter completionHandler: called from a background thread. Returns the sampled result `[Float]` or `Error`.
    ///
    /// Calls the completionHandler on a background thread.
    @available(*, deprecated, renamed: "samples(fromAudioAt:count:qos:)")
    public func samples(fromAudioAt audioAssetURL: URL, count: Int, qos: DispatchQoS.QoSClass = .userInitiated, completionHandler: @escaping (Result<[Float], Error>) -> ()) {
        Task {
            do {
                let samples = try await samples(fromAudioAt: audioAssetURL, count: count, qos: qos)
                completionHandler(.success(samples))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }
}

// MARK: - Private

fileprivate extension WaveformAnalyzer {
    func waveformSamples(
            track audioAssetTrack: AVAssetTrack,
            reader assetReader: AVAssetReader,
            count requiredNumberOfSamples: Int,
            fftBands: Int?
    ) async throws -> WaveformAnalysis {
        
        guard requiredNumberOfSamples > 0 else {
            throw AnalyzeError.userError
        }

        let trackOutput = AVAssetReaderTrackOutput(track: audioAssetTrack, outputSettings: outputSettings())
        assetReader.add(trackOutput)

        let totalSamples = try await totalSamples(of: audioAssetTrack)
        let analysis = extract(totalSamples, downsampledTo: requiredNumberOfSamples, from: assetReader, fftBands: fftBands)

        switch assetReader.status {
        case .completed:
            return analysis
        case .failed:
            if let error = assetReader.error {
                print("🔴 AssetReader error: \(error)")
            }
            // Instead of throwing, try to return what we have if we got any samples
            if !analysis.amplitudes.isEmpty {
                return analysis
            }
            throw AnalyzeError.readerError(assetReader.status)
        case .cancelled:
            throw AnalyzeError.readerError(assetReader.status)
        default:
            print("ERROR: reading waveform audio data has failed \(assetReader.status)")
            // Try to return partial results if available
            if !analysis.amplitudes.isEmpty {
                return analysis
            }
            throw AnalyzeError.readerError(assetReader.status)
        }
    }

    func extract(
        _ totalSamples: Int,
        downsampledTo targetSampleCount: Int,
        from assetReader: AVAssetReader,
        fftBands: Int?
    ) -> WaveformAnalysis {
        var outputSamples = [Float]()
        var outputFFT = fftBands == nil ? nil : [TempiFFT]()
        var sampleBuffer = Data()
        var sampleBufferFFT = Data()

        // read upfront to avoid frequent re-calculation (and memory bloat from C-bridging)
        let samplesPerPixel = max(1, totalSamples / targetSampleCount)
        let samplesPerFFT = 4096 // ~100ms at 44.1kHz, rounded to closest pow(2) for FFT

        assetReader.startReading()
        
        var loopCount = 0
        let maxLoops = 10000 // Increased limit but still safety net
        
        // Process samples in larger batches for better performance
        let batchProcessingThreshold = samplesPerPixel * 10 // Process when we have enough for 10 pixels
        
        while assetReader.status == .reading && loopCount < maxLoops {
            loopCount += 1
            
            guard let trackOutput = assetReader.outputs.first else {
                break
            }
            
            guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }
            
            guard let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                CMSampleBufferInvalidate(nextSampleBuffer)
                continue
            }

            var readBufferLength = 0
            var readBufferPointer: UnsafeMutablePointer<Int8>? = nil
            
            let result = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &readBufferLength, totalLengthOut: nil, dataPointerOut: &readBufferPointer)
            
            if result != kCMBlockBufferNoErr {
                CMSampleBufferInvalidate(nextSampleBuffer)
                continue
            }
            
            guard readBufferLength > 0, let pointer = readBufferPointer else {
                CMSampleBufferInvalidate(nextSampleBuffer)
                continue
            }
            
            sampleBuffer.append(UnsafeBufferPointer(start: pointer, count: readBufferLength))
            
            if fftBands != nil {
                sampleBufferFFT.append(UnsafeBufferPointer(start: pointer, count: readBufferLength))
            }
            
            CMSampleBufferInvalidate(nextSampleBuffer)

            // Only process when we have enough data for efficient batch processing
            let availableSamples = sampleBuffer.count / MemoryLayout<Int16>.size
            if availableSamples >= batchProcessingThreshold || assetReader.status != .reading {
                let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
                outputSamples += processedSamples

                if processedSamples.count > 0 {
                    let bytesToRemove = processedSamples.count * samplesPerPixel * MemoryLayout<Int16>.size
                    if bytesToRemove <= sampleBuffer.count {
                        sampleBuffer.removeFirst(bytesToRemove)
                        sampleBuffer = Data(sampleBuffer)
                    }
                }
                
            }

            if let fftBands = fftBands, sampleBufferFFT.count / MemoryLayout<Int16>.size >= samplesPerFFT {
                let processedFFTs = process(sampleBufferFFT, samplesPerFFT: samplesPerFFT, fftBands: fftBands)
                let bytesToRemove = processedFFTs.count * samplesPerFFT * MemoryLayout<Int16>.size
                if bytesToRemove <= sampleBufferFFT.count {
                    sampleBufferFFT.removeFirst(bytesToRemove)
                }
                outputFFT? += processedFFTs
            }
            
            // Early exit if we have enough samples
            if outputSamples.count >= targetSampleCount {
                break
            }
        }
        
        // Process any remaining data in the buffer
        if sampleBuffer.count > 0 && outputSamples.count < targetSampleCount {
            let remainingProcessed = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
            outputSamples += remainingProcessed
        }
        
        // Handle case where we still don't have enough samples
        if outputSamples.count < targetSampleCount {
            let missingSampleCount = (targetSampleCount - outputSamples.count) * samplesPerPixel
            let backfillPaddingSampleCount = missingSampleCount - (sampleBuffer.count / MemoryLayout<Int16>.size)
            
            if backfillPaddingSampleCount > 0 {
                let backfillPaddingSampleCount16 = backfillPaddingSampleCount * MemoryLayout<Int16>.size
                let backfillPaddingSamples = [UInt8](repeating: 0, count: backfillPaddingSampleCount16)
                sampleBuffer.append(backfillPaddingSamples, count: backfillPaddingSampleCount16)
                
                let processedSamples = process(sampleBuffer, from: assetReader, downsampleTo: samplesPerPixel)
                outputSamples += processedSamples
            }
        }

        let finalSampleCount = min(targetSampleCount, outputSamples.count)
        let targetSamples = Array(outputSamples[0..<finalSampleCount])
        return WaveformAnalysis(amplitudes: normalize(targetSamples), fft: outputFFT)
    }
    
    

    private func process(_ sampleBuffer: Data, from assetReader: AVAssetReader, downsampleTo samplesPerPixel: Int) -> [Float] {
        var downSampledData = [Float]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size

        // guard for crash in very long audio files
        guard sampleLength / samplesPerPixel > 0 else { return downSampledData }

        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress!
            var loudestClipValue: Float = 0.0
            var quietestClipValue = noiseFloorDecibelCutoff
            var zeroDbEquivalent: Float = Float(Int16.max) // maximum amplitude storable in Int16 = 0 Db (loudest)
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float (
            vDSP_vabs(processingBuffer, 1, &processingBuffer, 1, samplesToProcess) // absolute amplitude value
            vDSP_vdbcon(processingBuffer, 1, &zeroDbEquivalent, &processingBuffer, 1, samplesToProcess, 1) // convert to DB
            vDSP_vclip(processingBuffer, 1, &quietestClipValue, &loudestClipValue, &processingBuffer, 1, samplesToProcess)

            let filter = [Float](repeating: 1.0 / Float(samplesPerPixel), count: samplesPerPixel)
            let downSampledLength = sampleLength / samplesPerPixel
            downSampledData = [Float](repeating: 0.0, count: downSampledLength)

            vDSP_desamp(processingBuffer,
                        vDSP_Stride(samplesPerPixel),
                        filter,
                        &downSampledData,
                        vDSP_Length(downSampledLength),
                        vDSP_Length(samplesPerPixel))
        }

        return downSampledData
    }

    private func process(_ sampleBuffer: Data, samplesPerFFT: Int, fftBands: Int) -> [TempiFFT] {
        var ffts = [TempiFFT]()
        let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
        sampleBuffer.withUnsafeBytes { (samplesRawPointer: UnsafeRawBufferPointer) in
            let unsafeSamplesBufferPointer = samplesRawPointer.bindMemory(to: Int16.self)
            let unsafeSamplesPointer = unsafeSamplesBufferPointer.baseAddress!
            let samplesToProcess = vDSP_Length(sampleLength)

            var processingBuffer = [Float](repeating: 0.0, count: Int(samplesToProcess))
            vDSP_vflt16(unsafeSamplesPointer, 1, &processingBuffer, 1, samplesToProcess) // convert 16bit int to float

            repeat {
                let fftBuffer = processingBuffer[0..<samplesPerFFT]
                let fft = TempiFFT(withSize: samplesPerFFT, sampleRate: 44100.0)
                fft.windowType = TempiFFTWindowType.hanning
                fft.fftForward(Array(fftBuffer))
                fft.calculateLinearBands(minFrequency: 0, maxFrequency: fft.nyquistFrequency, numberOfBands: fftBands)
                ffts.append(fft)

                processingBuffer.removeFirst(samplesPerFFT)
            } while processingBuffer.count >= samplesPerFFT
        }
        return ffts
    }

    func normalize(_ samples: [Float]) -> [Float] {
        samples.map { $0 / noiseFloorDecibelCutoff }
    }

    private func totalSamples(of audioAssetTrack: AVAssetTrack) async throws -> Int {
        var totalSamples = 0
        
        do {
            let (descriptions, timeRange) = try await audioAssetTrack.load(.formatDescriptions, .timeRange)

            descriptions.forEach { formatDescription in
                guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                    return
                }
                let channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
                let sampleRate = basicDescription.pointee.mSampleRate
                totalSamples = Int(sampleRate * timeRange.duration.seconds) * channelCount
            }
        } catch {
            throw error
        }
        
        return totalSamples
    }
}

// MARK: - Configuration

private extension WaveformAnalyzer {
    func outputSettings() -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    func taskPriority(qos: DispatchQoS.QoSClass) -> TaskPriority {
        switch qos {
        case .background: return .background
        case .utility: return .utility
        case .default: return .medium
        case .userInitiated: return .userInitiated
        case .userInteractive: return .high
        case .unspecified: return .medium
        @unknown default: return .medium
        }
    }
}
