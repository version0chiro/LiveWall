import Compression
import CoreGraphics
import Foundation
import ImageIO

struct SceneWaveEffect {
    let mask: SceneMask?
    let direction: Float
    let speed: Float
    let scale: Float
    let strength: Float
    let perspective: Float
}

struct SceneMask {
    let width: Int
    let height: Int
    let pixels: Data
}

struct SceneAudioTrack {
    let data: Data
    let volume: Float
    let loops: Bool
}

/// Decoded, immutable resources shared by every display window for one scene.
final class SceneWallpaper {
    let image: CGImage
    let canvasSize: CGSize
    let waveEffects: [SceneWaveEffect]
    let showsRain: Bool
    let audioTrack: SceneAudioTrack?

    private init(
        image: CGImage,
        canvasSize: CGSize,
        waveEffects: [SceneWaveEffect],
        showsRain: Bool,
        audioTrack: SceneAudioTrack?
    ) {
        self.image = image
        self.canvasSize = canvasSize
        self.waveEffects = waveEffects
        self.showsRain = showsRain
        self.audioTrack = audioTrack
    }

    static func load(project: WallpaperProject) throws -> SceneWallpaper {
        guard project.kind == .scene, let packageURL = project.entryURL else {
            throw SceneWallpaperError.missingPackage
        }

        let package = try ScenePackageArchive(url: packageURL)
        let root = try package.jsonObject(named: "scene.json")
        let general = root["general"] as? [String: Any]
        let projection = general?["orthogonalprojection"] as? [String: Any]
        let canvasWidth = Self.number(projection?["width"]) ?? 1920
        let canvasHeight = Self.number(projection?["height"]) ?? 1080
        let objects = root["objects"] as? [[String: Any]] ?? []

        let imageObject = objects.first {
            Self.bool($0["visible"], defaultValue: true)
                && Self.string($0["image"]) != nil
        }

        let image: CGImage
        var waveEffects: [SceneWaveEffect] = []
        if let imageObject,
           let modelPath = Self.string(imageObject["image"]) {
            let model = try package.jsonObject(named: modelPath)
            guard let materialPath = Self.string(model["material"]) else {
                throw SceneWallpaperError.invalidScene(
                    "The primary model does not reference a material."
                )
            }
            let material = try package.jsonObject(named: materialPath)
            guard let passes = material["passes"] as? [[String: Any]],
                  let firstPass = passes.first,
                  let textures = firstPass["textures"] as? [Any],
                  let textureName = textures.first as? String else {
                throw SceneWallpaperError.invalidScene(
                    "The primary material does not reference a texture."
                )
            }
            let texturePath = Self.texturePath(textureName)
            let texture = try SceneTexture(data: package.data(named: texturePath))
            image = try texture.makeImage()
            waveEffects = try Self.loadWaveEffects(
                from: imageObject,
                package: package
            )
        } else if let previewURL = project.previewURL,
                  let source = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
                  let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = preview
        } else {
            throw SceneWallpaperError.invalidScene(
                "No supported image layer or preview was found."
            )
        }

        let showsRain = objects.contains {
            guard Self.bool($0["visible"], defaultValue: true),
                  let particle = Self.string($0["particle"]) else {
                return false
            }
            return particle.lowercased().contains("rain")
        }

        let audioTrack = try Self.loadAudio(from: objects, package: package)
        return SceneWallpaper(
            image: image,
            canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
            waveEffects: waveEffects,
            showsRain: showsRain,
            audioTrack: audioTrack
        )
    }

    private static func loadWaveEffects(
        from imageObject: [String: Any],
        package: ScenePackageArchive
    ) throws -> [SceneWaveEffect] {
        guard let effects = imageObject["effects"] as? [[String: Any]] else {
            return []
        }

        return try effects.compactMap { effect in
            guard bool(effect["visible"], defaultValue: true),
                  let effectPath = string(effect["file"]),
                  effectPath.lowercased().contains("waterwaves"),
                  let passes = effect["passes"] as? [[String: Any]],
                  let pass = passes.first else {
                return nil
            }

            let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
            let passTextures = pass["textures"] as? [Any] ?? []
            let maskName = passTextures.count > 1
                ? passTextures[1] as? String
                : nil
            let mask: SceneMask?
            if let maskName {
                let texture = try SceneTexture(
                    data: package.data(named: texturePath(maskName))
                )
                mask = try texture.makeMask()
            } else {
                mask = nil
            }

            return SceneWaveEffect(
                mask: mask,
                direction: Float(number(constants["direction"]) ?? 0),
                speed: Float(number(constants["speed"]) ?? 5),
                scale: Float(number(constants["scale"]) ?? 200),
                strength: Float(number(constants["strength"]) ?? 0.1),
                perspective: Float(number(constants["perspective"]) ?? 0)
            )
        }
    }

    private static func loadAudio(
        from objects: [[String: Any]],
        package: ScenePackageArchive
    ) throws -> SceneAudioTrack? {
        for object in objects where bool(object["visible"], defaultValue: true) {
            guard let sounds = object["sound"] as? [String],
                  let soundPath = sounds.first else {
                continue
            }
            return SceneAudioTrack(
                data: try package.data(named: soundPath),
                volume: Float(number(object["volume"]) ?? 1).clamped(to: 0...1),
                loops: string(object["playbackmode"])?.lowercased() == "loop"
            )
        }
        return nil
    }

    private static func texturePath(_ name: String) -> String {
        var path = name
        if !path.hasPrefix("materials/") {
            path = "materials/" + path
        }
        if URL(fileURLWithPath: path).pathExtension.isEmpty {
            path += ".tex"
        }
        return path
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        (value as? NSNumber)?.boolValue ?? defaultValue
    }
}

/// Bounds-checked reader for Wallpaper Engine's index-based PKGV package.
struct ScenePackageArchive {
    let version: String
    let names: [String]

    private let storage: Data
    private let entries: [String: Range<Int>]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var cursor = SceneDataCursor(data: data)
        let versionLength = try cursor.readUInt32()
        guard versionLength > 0, versionLength <= 64 else {
            throw SceneWallpaperError.invalidPackage("Invalid package version length.")
        }
        let version = try cursor.readString(count: Int(versionLength))
        guard version.hasPrefix("PKGV") else {
            throw SceneWallpaperError.invalidPackage(
                "Unsupported package signature \(version)."
            )
        }

        let fileCount = try cursor.readUInt32()
        guard fileCount > 0, fileCount <= 50_000 else {
            throw SceneWallpaperError.invalidPackage("Invalid package file count.")
        }

        var indexedEntries: [(String, UInt32, UInt32)] = []
        indexedEntries.reserveCapacity(Int(fileCount))
        var seenNames = Set<String>()

        for _ in 0..<fileCount {
            let pathLength = try cursor.readUInt32()
            guard pathLength > 0, pathLength <= 4_096 else {
                throw SceneWallpaperError.invalidPackage(
                    "Invalid package path length."
                )
            }
            let path = try cursor.readString(count: Int(pathLength))
            guard Self.isSafeArchivePath(path), seenNames.insert(path).inserted else {
                throw SceneWallpaperError.invalidPackage(
                    "Unsafe or duplicate package path \(path)."
                )
            }
            let offset = try cursor.readUInt32()
            let size = try cursor.readUInt32()
            indexedEntries.append((path, offset, size))
        }

        let dataStart = cursor.offset
        var ranges: [String: Range<Int>] = [:]
        for (path, rawOffset, rawSize) in indexedEntries {
            let start = dataStart.addingReportingOverflow(Int(rawOffset))
            let end = start.partialValue.addingReportingOverflow(Int(rawSize))
            guard !start.overflow, !end.overflow,
                  start.partialValue >= dataStart,
                  end.partialValue <= data.count else {
                throw SceneWallpaperError.invalidPackage(
                    "Package entry \(path) extends beyond the file."
                )
            }
            ranges[path] = start.partialValue..<end.partialValue
        }

        self.version = version
        self.names = indexedEntries.map(\.0)
        self.storage = data
        self.entries = ranges
    }

    func data(named name: String) throws -> Data {
        guard let range = entries[name] else {
            throw SceneWallpaperError.missingAsset(name)
        }
        return storage.subdata(in: range)
    }

    func jsonObject(named name: String) throws -> [String: Any] {
        let raw = try data(named: name)
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw SceneWallpaperError.invalidScene(
                "\(name) is not valid JSON: \(error.localizedDescription)"
            )
        }
        guard let object = decoded as? [String: Any] else {
            throw SceneWallpaperError.invalidScene(
                "\(name) must contain a JSON object."
            )
        }
        return object
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.utf8.contains(0) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct SceneTexture {
    let format: UInt32
    let width: Int
    let height: Int
    let payload: Data

    init(data: Data) throws {
        var cursor = SceneDataCursor(data: data)
        let version = try cursor.readString(count: 8)
        try cursor.skip(1)
        let infoVersion = try cursor.readString(count: 8)
        try cursor.skip(1)
        guard version.hasPrefix("TEXV"), infoVersion.hasPrefix("TEXI") else {
            throw SceneWallpaperError.invalidTexture("Invalid texture signature.")
        }

        format = try cursor.readUInt32()
        try cursor.skip(4)
        width = Int(try cursor.readUInt32())
        height = Int(try cursor.readUInt32())
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw SceneWallpaperError.invalidTexture("Invalid texture dimensions.")
        }
        try cursor.skip(12)
        let blockVersion = try cursor.readString(count: 8)
        try cursor.skip(1)
        guard blockVersion.hasPrefix("TEXB") else {
            throw SceneWallpaperError.invalidTexture("Invalid texture block.")
        }
        _ = try cursor.readUInt32()
        try cursor.skip(8)
        if blockVersion.hasSuffix("4") {
            _ = try cursor.readUInt32()
        }
        try cursor.skip(8)
        let usesLZ4 = try cursor.readUInt32() == 1
        let decompressedSize = Int(try cursor.readUInt32())
        let payloadSize = Int(try cursor.readUInt32())
        let encoded = try cursor.readData(count: payloadSize)

        if usesLZ4 {
            guard decompressedSize > 0, decompressedSize <= 512 * 1024 * 1024 else {
                throw SceneWallpaperError.invalidTexture(
                    "Invalid decompressed texture size."
                )
            }
            payload = try Self.decompressLZ4(
                encoded,
                outputSize: decompressedSize
            )
        } else {
            payload = encoded
        }
    }

    func makeImage() throws -> CGImage {
        guard format == 0,
              let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SceneWallpaperError.unsupportedTexture(
                "This scene's main image is not an embedded PNG or JPEG."
            )
        }
        return image
    }

    func makeMask() throws -> SceneMask {
        let expectedPixels = width * height
        switch format {
        case 9:
            guard payload.count >= expectedPixels else {
                throw SceneWallpaperError.invalidTexture(
                    "The R8 mask is shorter than its dimensions."
                )
            }
            return SceneMask(
                width: width,
                height: height,
                pixels: payload.prefix(expectedPixels)
            )
        case 8:
            guard payload.count >= expectedPixels * 2 else {
                throw SceneWallpaperError.invalidTexture(
                    "The RG88 mask is shorter than its dimensions."
                )
            }
            var red = Data(count: expectedPixels)
            red.withUnsafeMutableBytes { output in
                payload.withUnsafeBytes { input in
                    guard let destination = output.bindMemory(to: UInt8.self).baseAddress,
                          let source = input.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for index in 0..<expectedPixels {
                        destination[index] = source[index * 2]
                    }
                }
            }
            return SceneMask(width: width, height: height, pixels: red)
        default:
            throw SceneWallpaperError.unsupportedTexture(
                "Only R8 and RG88 effect masks are supported."
            )
        }
    }

    private static func decompressLZ4(
        _ source: Data,
        outputSize: Int
    ) throws -> Data {
        var output = Data(count: outputSize)
        let decodedCount = output.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { encoded in
                guard let destinationAddress =
                        destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceAddress =
                        encoded.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationAddress,
                    outputSize,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard decodedCount == outputSize else {
            throw SceneWallpaperError.invalidTexture(
                "The LZ4 texture payload could not be decompressed."
            )
        }
        return output
    }
}

private struct SceneDataCursor {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return UInt32(bytes[bytes.startIndex])
            | UInt32(bytes[bytes.startIndex + 1]) << 8
            | UInt32(bytes[bytes.startIndex + 2]) << 16
            | UInt32(bytes[bytes.startIndex + 3]) << 24
    }

    mutating func readString(count: Int) throws -> String {
        let bytes = try readData(count: count)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw SceneWallpaperError.invalidPackage("Invalid UTF-8 string.")
        }
        return string
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count,
              count <= data.count - offset else {
            throw SceneWallpaperError.unexpectedEndOfFile
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func skip(_ count: Int) throws {
        _ = try readData(count: count)
    }
}

enum SceneWallpaperError: LocalizedError {
    case missingPackage
    case invalidPackage(String)
    case missingAsset(String)
    case invalidScene(String)
    case invalidTexture(String)
    case unsupportedTexture(String)
    case metalUnavailable
    case rendererInitialization(String)
    case snapshotFailed(String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .missingPackage:
            return "The scene.pkg file is missing."
        case .invalidPackage(let reason):
            return "Invalid scene package: \(reason)"
        case .missingAsset(let path):
            return "The scene package is missing \(path)."
        case .invalidScene(let reason):
            return "Invalid scene: \(reason)"
        case .invalidTexture(let reason):
            return "Invalid scene texture: \(reason)"
        case .unsupportedTexture(let reason):
            return "Unsupported scene texture: \(reason)"
        case .metalUnavailable:
            return "Metal is unavailable on this Mac."
        case .rendererInitialization(let reason):
            return "The scene renderer could not start: \(reason)"
        case .snapshotFailed(let reason):
            return "The scene snapshot could not be created: \(reason)"
        case .unexpectedEndOfFile:
            return "The scene package ended unexpectedly."
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
