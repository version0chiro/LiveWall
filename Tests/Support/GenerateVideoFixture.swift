import AVFoundation
import CoreVideo
import Foundation

enum FixtureError: LocalizedError {
    case usage
    case couldNotCreatePixelBuffer
    case couldNotStartWriter(String)
    case couldNotAppendFrame(Int)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: GenerateVideoFixture <output-directory>"
        case .couldNotCreatePixelBuffer:
            return "Could not allocate a video pixel buffer."
        case .couldNotStartWriter(let message):
            return "Could not start the video writer: \(message)"
        case .couldNotAppendFrame(let frame):
            return "Could not append video frame \(frame)."
        case .writerFailed(let message):
            return "Video writer failed: \(message)"
        }
    }
}

@main
struct GenerateVideoFixture {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw FixtureError.usage
            }

            let outputDirectory = URL(
                fileURLWithPath: CommandLine.arguments[1],
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let videoURL = outputDirectory.appendingPathComponent("wallpaper.mov")
            if FileManager.default.fileExists(atPath: videoURL.path) {
                try FileManager.default.removeItem(at: videoURL)
            }

            let width = 160
            let height = 96
            let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
            )
            input.expectsMediaDataInRealTime = false

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            guard writer.canAdd(input) else {
                throw FixtureError.couldNotStartWriter("writer rejected its video input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw FixtureError.couldNotStartWriter(
                    writer.error?.localizedDescription ?? "unknown error"
                )
            }
            writer.startSession(atSourceTime: .zero)

            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard let pool = adaptor.pixelBufferPool else {
                    throw FixtureError.couldNotCreatePixelBuffer
                }
                var optionalBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pool,
                    &optionalBuffer
                ) == kCVReturnSuccess, let buffer = optionalBuffer else {
                    throw FixtureError.couldNotCreatePixelBuffer
                }

                fill(buffer: buffer, frame: frame, width: width, height: height)
                let presentationTime = CMTime(value: CMTimeValue(frame), timescale: 30)
                guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                    throw FixtureError.couldNotAppendFrame(frame)
                }
            }

            input.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting {
                semaphore.signal()
            }
            semaphore.wait()
            guard writer.status == .completed else {
                throw FixtureError.writerFailed(
                    writer.error?.localizedDescription ?? "unknown error"
                )
            }

            let manifest: [String: Any] = [
                "file": videoURL.lastPathComponent,
                "title": "LiveWall Video Smoke Test",
                "type": "video",
                "version": 1
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
            try manifestData.write(
                to: outputDirectory.appendingPathComponent("project.json")
            )
            print(outputDirectory.appendingPathComponent("project.json").path)
        } catch {
            fputs("GenerateVideoFixture failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func fill(
        buffer: CVPixelBuffer,
        frame: Int,
        width: Int,
        height: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x * 2 + frame * 7) % 255)
                pixels[offset + 1] = UInt8((y * 4 + frame * 3) % 255)
                pixels[offset + 2] = UInt8((frame * 8) % 255)
                pixels[offset + 3] = 255
            }
        }
    }
}
