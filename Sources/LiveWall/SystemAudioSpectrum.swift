import Accelerate
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioSpectrumError: LocalizedError {
    case noDisplay
    case captureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display was available for system-audio capture."
        case .captureUnavailable(let reason):
            return "System-audio capture could not start: \(reason)"
        }
    }
}

/// Captures macOS system audio with ScreenCaptureKit and converts it into the
/// 128 normalized values expected by Wallpaper Engine web audio listeners.
final class SystemAudioSpectrumCapture: NSObject, SCStreamOutput {

    var onSpectrum: (([Float]) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "LiveWall.AudioSpectrum",
        qos: .userInteractive
    )
    private let fftLength = 1024
    private let fftLog2: vDSP_Length = 10
    private var fftSetup: FFTSetup?
    private var stream: SCStream?
    private var sampleAccumulator: [Float] = []
    private var lastPublishedAt = CFAbsoluteTimeGetCurrent()

    override init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        super.init()
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func start() async throws {
        guard stream == nil else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw SystemAudioSpectrumError.noDisplay
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(
                seconds: 1,
                preferredTimescale: 1
            )
            configuration.queueDepth = 2
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: nil
            )
            try stream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: processingQueue
            )
            try await stream.startCapture()
            self.stream = stream
        } catch let error as SystemAudioSpectrumError {
            throw error
        } catch {
            throw SystemAudioSpectrumError.captureUnavailable(
                error.localizedDescription
            )
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        sampleAccumulator.removeAll(keepingCapacity: false)
        Task {
            try? await stream.stopCapture()
        }
    }

    func analyzeForTesting(samples: [Float]) -> [Float] {
        makeSpectrum(from: samples)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let samples = monoFloatSamples(from: sampleBuffer),
              !samples.isEmpty else {
            return
        }

        sampleAccumulator.append(contentsOf: samples)
        if sampleAccumulator.count > fftLength * 4 {
            sampleAccumulator.removeFirst(sampleAccumulator.count - fftLength * 2)
        }

        guard sampleAccumulator.count >= fftLength else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublishedAt >= 1.0 / 30.0 else { return }
        lastPublishedAt = now

        let frame = Array(sampleAccumulator.suffix(fftLength))
        let spectrum = makeSpectrum(from: frame)
        DispatchQueue.main.async { [weak self] in
            self?.onSpectrum?(spectrum)
        }
    }

    private func monoFloatSamples(
        from sampleBuffer: CMSampleBuffer
    ) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(
            sampleBuffer
        ),
        let streamDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee,
        streamDescription.mFormatID == kAudioFormatLinearPCM,
        streamDescription.mBitsPerChannel == 32,
        streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            return nil
        }

        let maximumBuffers = 8
        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * (maximumBuffers - 1)
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let audioBufferList = rawPointer.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )
        var retainedBlockBuffer: CMBlockBuffer?
        var requiredSize = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        var result: [Float] = []

        if buffers.count == 1, let data = buffers[0].mData {
            let floatCount = Int(buffers[0].mDataByteSize)
                / MemoryLayout<Float>.size
            let pointer = data.bindMemory(to: Float.self, capacity: floatCount)
            if channelCount == 1 {
                result = Array(UnsafeBufferPointer(
                    start: pointer,
                    count: floatCount
                ))
            } else {
                let frameCount = floatCount / channelCount
                result.reserveCapacity(frameCount)
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += pointer[frame * channelCount + channel]
                    }
                    result.append(sum / Float(channelCount))
                }
            }
        } else {
            let usableBuffers = min(buffers.count, channelCount)
            guard usableBuffers > 0 else { return nil }
            let frameCount = buffers.prefix(usableBuffers).map {
                Int($0.mDataByteSize) / MemoryLayout<Float>.size
            }.min() ?? 0
            result = [Float](repeating: 0, count: frameCount)
            for bufferIndex in 0..<usableBuffers {
                guard let data = buffers[bufferIndex].mData else { continue }
                let pointer = data.bindMemory(
                    to: Float.self,
                    capacity: frameCount
                )
                for index in 0..<frameCount {
                    result[index] += pointer[index] / Float(usableBuffers)
                }
            }
        }
        return result
    }

    private func makeSpectrum(from samples: [Float]) -> [Float] {
        guard let fftSetup, samples.count == fftLength else {
            return [Float](repeating: 0, count: 128)
        }

        var window = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(
            &window,
            vDSP_Length(fftLength),
            Int32(vDSP_HANN_NORM)
        )
        var windowed = [Float](repeating: 0, count: fftLength)
        vDSP_vmul(
            samples,
            1,
            window,
            1,
            &windowed,
            1,
            vDSP_Length(fftLength)
        )

        let halfLength = fftLength / 2
        var real = [Float](repeating: 0, count: halfLength)
        var imaginary = [Float](repeating: 0, count: halfLength)
        var magnitudes = [Float](repeating: 0, count: halfLength)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                windowed.withUnsafeBufferPointer { inputBuffer in
                    inputBuffer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfLength
                    ) { complexBuffer in
                        vDSP_ctoz(
                            complexBuffer,
                            2,
                            &split,
                            1,
                            vDSP_Length(halfLength)
                        )
                    }
                }
                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    fftLog2,
                    FFTDirection(FFT_FORWARD)
                )
                vDSP_zvmags(
                    &split,
                    1,
                    &magnitudes,
                    1,
                    vDSP_Length(halfLength)
                )
            }
        }

        var bands = [Float](repeating: 0, count: 64)
        let minimumFrequency = 35.0
        let maximumFrequency = 16_000.0
        let sampleRate = 48_000.0
        for band in 0..<bands.count {
            let startRatio = Double(band) / Double(bands.count)
            let endRatio = Double(band + 1) / Double(bands.count)
            let startFrequency = minimumFrequency
                * pow(maximumFrequency / minimumFrequency, startRatio)
            let endFrequency = minimumFrequency
                * pow(maximumFrequency / minimumFrequency, endRatio)
            let startBin = max(
                1,
                min(
                    halfLength - 1,
                    Int(startFrequency * Double(fftLength) / sampleRate)
                )
            )
            let endBin = max(
                startBin + 1,
                min(
                    halfLength,
                    Int(endFrequency * Double(fftLength) / sampleRate)
                )
            )
            let peakPower = magnitudes[startBin..<endBin].max() ?? 0
            let amplitude = sqrt(max(peakPower, 0)) / Float(fftLength)
            let decibels = 20 * log10(max(amplitude, 0.000_001))
            bands[band] = min(1, max(0, (decibels + 60) / 60))
        }
        return bands + bands
    }
}
