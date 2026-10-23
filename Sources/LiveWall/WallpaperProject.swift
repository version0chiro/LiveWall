import Foundation

enum WallpaperPropertyValue: Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init?(jsonValue: Any) {
        if let value = jsonValue as? Bool {
            self = .bool(value)
        } else if let value = jsonValue as? NSNumber {
            self = .number(value.doubleValue)
        } else if let value = jsonValue as? String {
            self = .string(value)
        } else {
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    var displayValue: String {
        switch self {
        case .bool(let value): return value ? "On" : "Off"
        case .number(let value):
            return value.rounded() == value
                ? String(Int(value))
                : String(format: "%.2f", value)
        case .string(let value): return value
        }
    }
}

enum WallpaperPropertyKind: String, Equatable {
    case bool
    case slider
    case combo
    case textInput = "textinput"
    case color
    case file
    case group
    case unknown
}

struct WallpaperPropertyOption: Equatable {
    let label: String
    let value: WallpaperPropertyValue
}

struct WallpaperPropertyDefinition: Equatable {
    let name: String
    let kind: WallpaperPropertyKind
    let label: String
    let order: Int
    let defaultValue: WallpaperPropertyValue?
    let minimum: Double?
    let maximum: Double?
    let step: Double?
    let options: [WallpaperPropertyOption]

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.hasPrefix("ui_") {
            return trimmed
        }
        return name
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

enum WallpaperProjectKind: String, CaseIterable {
    case video
    case web
    case scene
    case application
    case unknown

    var isSupported: Bool {
        self == .video || self == .web || self == .scene
    }

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .web: return "Web"
        case .scene: return "Scene"
        case .application: return "Application"
        case .unknown: return "Unknown"
        }
    }
}

struct WallpaperProject: Equatable {
    let manifestURL: URL
    let directoryURL: URL
    let title: String
    let kind: WallpaperProjectKind
    let entryURL: URL?
    let previewURL: URL?
    let workshopID: String?
    let defaultUserPropertiesJSON: String
    let propertyDefinitions: [WallpaperPropertyDefinition]
    let supportsAudioProcessing: Bool

    var isSupported: Bool {
        kind.isSupported && entryURL != nil
    }

    var defaultPropertyValues: [String: WallpaperPropertyValue] {
        Dictionary(uniqueKeysWithValues: propertyDefinitions.compactMap {
            guard let value = $0.defaultValue else { return nil }
            return ($0.name, value)
        })
    }

    func userPropertiesJSON(
        overrides: [String: WallpaperPropertyValue]
    ) -> String {
        var values = defaultPropertyValues
        for definition in propertyDefinitions {
            if let value = overrides[definition.name] {
                values[definition.name] = value
            }
        }

        let object = values.mapValues { ["value": $0.jsonValue] }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return defaultUserPropertiesJSON
        }
        return json
    }

    func userPropertyUpdateJSON(
        _ changes: [String: WallpaperPropertyValue]
    ) -> String {
        let knownNames = Set(propertyDefinitions.map(\.name))
        let object = changes
            .filter { knownNames.contains($0.key) }
            .mapValues { ["value": $0.jsonValue] }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct WallpaperScanIssue: Equatable {
    let path: String
    let message: String
}

struct WallpaperLibraryScan {
    let rootURL: URL
    let projects: [WallpaperProject]
    let issues: [WallpaperScanIssue]
    let wasTruncated: Bool

    var supportedProjects: [WallpaperProject] {
        projects.filter(\.isSupported)
    }

    var unsupportedProjects: [WallpaperProject] {
        projects.filter { !$0.isSupported }
    }
}

enum WallpaperProjectError: LocalizedError {
    case manifestNotFound(String)
    case invalidManifest(String)
    case missingEntryFile(String)
    case unsafeRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound(let path):
            return "No project.json was found at \(path)."
        case .invalidManifest(let reason):
            return "Invalid project.json: \(reason)"
        case .missingEntryFile(let path):
            return "The wallpaper entry file does not exist: \(path)"
        case .unsafeRelativePath(let path):
            return "The wallpaper references a file outside its project folder: \(path)"
        }
    }
}

struct WallpaperProjectLoader {
    static let manifestFilename = "project.json"

    static func load(manifestURL: URL) throws -> WallpaperProject {
        let manifestURL = manifestURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WallpaperProjectError.manifestNotFound(manifestURL.path)
        }

        let data = try Data(contentsOf: manifestURL)
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WallpaperProjectError.invalidManifest(error.localizedDescription)
        }
        guard let manifest = rawObject as? [String: Any] else {
            throw WallpaperProjectError.invalidManifest("the root value must be an object")
        }

        let directoryURL = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let rawType = stringValue(manifest["type"])?.lowercased()
        let file = stringValue(manifest["file"])
        let kind = projectKind(rawType: rawType, file: file)
        let title = nonEmpty(stringValue(manifest["title"]))
            ?? directoryURL.lastPathComponent
        let entryURL: URL?
        if kind == .scene {
            entryURL = try resolveScenePackage(
                declaredFile: file,
                inside: directoryURL
            )
        } else {
            entryURL = try resolveExistingAsset(
                file,
                inside: directoryURL,
                required: kind.isSupported
            )
        }
        let previewURL = try resolveExistingAsset(
            stringValue(manifest["preview"]),
            inside: directoryURL,
            required: false
        )
        let folderName = directoryURL.lastPathComponent
        let workshopID = folderName.allSatisfy(\.isNumber) ? folderName : nil
        let propertyDefinitions = parsePropertyDefinitions(
            from: manifest
        )
        let defaultUserPropertiesJSON = serializeDefaultUserProperties(
            definitions: propertyDefinitions
        )
        let supportsAudioProcessing =
            (manifest["general"] as? [String: Any])?["supportsaudioprocessing"]
                as? Bool ?? false

        return WallpaperProject(
            manifestURL: manifestURL,
            directoryURL: directoryURL,
            title: title,
            kind: kind,
            entryURL: entryURL,
            previewURL: previewURL,
            workshopID: workshopID,
            defaultUserPropertiesJSON: defaultUserPropertiesJSON,
            propertyDefinitions: propertyDefinitions,
            supportsAudioProcessing: supportsAudioProcessing
        )
    }

    static func scan(rootURL: URL, maximumProjects: Int = 10_000) -> WallpaperLibraryScan {
        let rootURL = rootURL.standardizedFileURL
        var manifestURLs: [URL] = []
        var issues: [WallpaperScanIssue] = []
        var wasTruncated = false

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return WallpaperLibraryScan(
                rootURL: rootURL,
                projects: [],
                issues: [WallpaperScanIssue(path: rootURL.path, message: "Folder does not exist.")],
                wasTruncated: false
            )
        }

        if !isDirectory.boolValue {
            if rootURL.lastPathComponent.lowercased() == manifestFilename {
                manifestURLs = [rootURL]
            } else {
                issues.append(WallpaperScanIssue(
                    path: rootURL.path,
                    message: "Choose a project.json file or a folder containing Wallpaper Engine projects."
                ))
            }
        } else {
            let directManifest = rootURL.appendingPathComponent(manifestFilename)
            if FileManager.default.fileExists(atPath: directManifest.path) {
                manifestURLs = [directManifest]
            } else if let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let candidate = enumerator.nextObject() as? URL {
                    guard candidate.lastPathComponent.lowercased() == manifestFilename else {
                        continue
                    }
                    manifestURLs.append(candidate)
                    if manifestURLs.count >= maximumProjects {
                        wasTruncated = true
                        issues.append(WallpaperScanIssue(
                            path: rootURL.path,
                            message: "Scan stopped after \(maximumProjects) project manifests."
                        ))
                        break
                    }
                }
            }
        }

        var projects: [WallpaperProject] = []
        for manifestURL in manifestURLs {
            do {
                projects.append(try load(manifestURL: manifestURL))
            } catch {
                issues.append(WallpaperScanIssue(
                    path: manifestURL.path,
                    message: error.localizedDescription
                ))
            }
        }

        projects.sort {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder == .orderedSame {
                return $0.manifestURL.path < $1.manifestURL.path
            }
            return titleOrder == .orderedAscending
        }

        return WallpaperLibraryScan(
            rootURL: rootURL,
            projects: projects,
            issues: issues,
            wasTruncated: wasTruncated
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func projectKind(rawType: String?, file: String?) -> WallpaperProjectKind {
        if let rawType, let exact = WallpaperProjectKind(rawValue: rawType) {
            return exact
        }

        switch URL(fileURLWithPath: file ?? "").pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "hevc":
            return .video
        case "html", "htm":
            return .web
        case "pkg":
            return .scene
        case "exe":
            return .application
        default:
            return .unknown
        }
    }

    /// Wallpaper Engine delivers the current value of every project property as
    /// `{ propertyName: { value: ... } }`. Preserve only those JSON-compatible
    /// defaults instead of exposing the rest of the untrusted manifest to the
    /// web page.
    private static func parsePropertyDefinitions(
        from manifest: [String: Any]
    ) -> [WallpaperPropertyDefinition] {
        guard let general = manifest["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else {
            return []
        }

        var definitions: [WallpaperPropertyDefinition] = []
        for (name, rawDescriptor) in properties {
            guard let descriptor = rawDescriptor as? [String: Any] else {
                continue
            }
            let rawKind = (descriptor["type"] as? String)?.lowercased() ?? ""
            let kind = WallpaperPropertyKind(rawValue: rawKind) ?? .unknown
            let label = descriptor["text"] as? String ?? name
            let order = (descriptor["order"] as? NSNumber)?.intValue
                ?? (descriptor["index"] as? NSNumber)?.intValue
                ?? Int.max
            let defaultValue = descriptor["value"]
                .flatMap(WallpaperPropertyValue.init(jsonValue:))
            let minimum = (descriptor["min"] as? NSNumber)?.doubleValue
            let maximum = (descriptor["max"] as? NSNumber)?.doubleValue
            let step = (descriptor["step"] as? NSNumber)?.doubleValue
            let rawOptions = descriptor["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { option
                -> WallpaperPropertyOption? in
                guard let rawValue = option["value"],
                      let value = WallpaperPropertyValue(jsonValue: rawValue) else {
                    return nil
                }
                return WallpaperPropertyOption(
                    label: option["label"] as? String ?? value.displayValue,
                    value: value
                )
            }

            definitions.append(WallpaperPropertyDefinition(
                name: name,
                kind: kind,
                label: label,
                order: order,
                defaultValue: defaultValue,
                minimum: minimum,
                maximum: maximum,
                step: step,
                options: options
            ))
        }
        return definitions.sorted {
            if $0.order == $1.order { return $0.name < $1.name }
            return $0.order < $1.order
        }
    }

    private static func serializeDefaultUserProperties(
        definitions: [WallpaperPropertyDefinition]
    ) -> String {
        let defaults = Dictionary(uniqueKeysWithValues: definitions.compactMap {
            definition -> (String, [String: Any])? in
            guard let value = definition.defaultValue else { return nil }
            return (definition.name, ["value": value.jsonValue])
        })

        guard JSONSerialization.isValidJSONObject(defaults),
              let data = try? JSONSerialization.data(
                  withJSONObject: defaults,
                  options: [.sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func resolveExistingAsset(
        _ relativePath: String?,
        inside directoryURL: URL,
        required: Bool
    ) throws -> URL? {
        guard let relativePath = nonEmpty(relativePath) else {
            if required {
                throw WallpaperProjectError.invalidManifest("supported projects must include a file field")
            }
            return nil
        }
        guard !NSString(string: relativePath).isAbsolutePath else {
            throw WallpaperProjectError.unsafeRelativePath(relativePath)
        }

        let candidate = directoryURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = directoryURL.path.hasSuffix("/") ? directoryURL.path : directoryURL.path + "/"
        guard candidate.path == directoryURL.path || candidate.path.hasPrefix(rootPath) else {
            throw WallpaperProjectError.unsafeRelativePath(relativePath)
        }

        guard FileManager.default.fileExists(atPath: candidate.path) else {
            if required {
                throw WallpaperProjectError.missingEntryFile(candidate.path)
            }
            return nil
        }
        return candidate
    }

    /// Scene manifests commonly declare the internal `scene.json` entry while
    /// Workshop downloads store that entry inside a sibling `scene.pkg`.
    private static func resolveScenePackage(
        declaredFile: String?,
        inside directoryURL: URL
    ) throws -> URL {
        let declaredExtension = URL(
            fileURLWithPath: declaredFile ?? ""
        ).pathExtension.lowercased()
        if declaredExtension == "pkg",
           let declared = try resolveExistingAsset(
               declaredFile,
               inside: directoryURL,
               required: false
           ) {
            return declared
        }

        guard let package = try resolveExistingAsset(
            "scene.pkg",
            inside: directoryURL,
            required: false
        ) else {
            throw WallpaperProjectError.missingEntryFile(
                directoryURL.appendingPathComponent("scene.pkg").path
            )
        }
        return package
    }
}
