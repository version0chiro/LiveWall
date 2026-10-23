import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.assertion(message)
    }
}

func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try data.write(to: url)
}

func makeScenePackage(entries: [(String, Data)]) -> Data {
    var data = Data()
    func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    let version = Data("PKGV0018".utf8)
    appendUInt32(UInt32(version.count))
    data.append(version)
    appendUInt32(UInt32(entries.count))

    var offset: UInt32 = 0
    for (name, contents) in entries {
        let path = Data(name.utf8)
        appendUInt32(UInt32(path.count))
        data.append(path)
        appendUInt32(offset)
        appendUInt32(UInt32(contents.count))
        offset += UInt32(contents.count)
    }
    for (_, contents) in entries {
        data.append(contents)
    }
    return data
}

func makeEmbeddedImageTexture(_ image: Data) -> Data {
    var data = Data()
    func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func appendZeros(_ count: Int) {
        data.append(Data(repeating: 0, count: count))
    }

    data.append(Data("TEXV0005".utf8))
    appendZeros(1)
    data.append(Data("TEXI0001".utf8))
    appendZeros(1)
    appendUInt32(0)
    appendZeros(4)
    appendUInt32(1)
    appendUInt32(1)
    appendZeros(12)
    data.append(Data("TEXB0003".utf8))
    appendZeros(1)
    appendUInt32(1)
    appendZeros(8)
    appendZeros(8)
    appendUInt32(0)
    appendUInt32(0)
    appendUInt32(UInt32(image.count))
    data.append(image)
    return data
}

@main
struct WallpaperProjectLoaderTests {
    static func main() {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallTests-\(UUID().uuidString)")

        do {
            try makeDirectory(temporaryRoot)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }

            let videoProjectURL = temporaryRoot.appendingPathComponent("123456789")
            try makeDirectory(videoProjectURL)
            let videoURL = videoProjectURL.appendingPathComponent("wallpaper.mp4")
            let previewURL = videoProjectURL.appendingPathComponent("preview.jpg")
            try Data().write(to: videoURL)
            try Data().write(to: previewURL)
            try writeJSON([
                "title": "Ocean Video",
                "type": "video",
                "file": "wallpaper.mp4",
                "preview": "preview.jpg"
            ], to: videoProjectURL.appendingPathComponent("project.json"))

            let video = try WallpaperProjectLoader.load(
                manifestURL: videoProjectURL.appendingPathComponent("project.json")
            )
            try expect(video.title == "Ocean Video", "Video title was not parsed.")
            try expect(video.kind == .video, "Video project type was not parsed.")
            try expect(video.entryURL == videoURL, "Video entry URL was not resolved.")
            try expect(video.previewURL == previewURL, "Preview URL was not resolved.")
            try expect(video.workshopID == "123456789", "Workshop ID was not inferred.")
            try expect(video.isSupported, "Video project should be supported.")

            let webProjectURL = temporaryRoot.appendingPathComponent("web-project")
            try makeDirectory(webProjectURL)
            let htmlURL = webProjectURL.appendingPathComponent("index.html")
            try "<html><body>LiveWall fixture</body></html>".write(
                to: htmlURL,
                atomically: true,
                encoding: .utf8
            )
            try writeJSON([
                "title": "Local Web",
                "type": "web",
                "file": "index.html",
                "general": [
                    "supportsaudioprocessing": true,
                    "properties": [
                        "enabled": ["type": "bool", "value": true],
                        "quality": [
                            "type": "slider",
                            "value": 75,
                            "min": 0,
                            "max": 100,
                            "step": 5
                        ],
                        "theme": [
                            "type": "combo",
                            "value": "dark",
                            "options": [
                                ["label": "Light", "value": "light"],
                                ["label": "Dark", "value": "dark"]
                            ]
                        ],
                        "missing": ["type": "text"]
                    ]
                ]
            ], to: webProjectURL.appendingPathComponent("project.json"))

            let web = try WallpaperProjectLoader.load(
                manifestURL: webProjectURL.appendingPathComponent("project.json")
            )
            let propertyData = try expectData(web.defaultUserPropertiesJSON)
            let properties = try JSONSerialization.jsonObject(with: propertyData)
                as? [String: [String: Any]]
            try expect(
                properties?["enabled"]?["value"] as? Bool == true,
                "Web boolean property default was not preserved."
            )
            try expect(
                properties?["quality"]?["value"] as? Int == 75,
                "Web numeric property default was not preserved."
            )
            try expect(
                properties?["theme"]?["value"] as? String == "dark",
                "Web string property default was not preserved."
            )
            try expect(
                properties?["missing"] == nil,
                "A property without a default value should be ignored."
            )
            try expect(
                web.supportsAudioProcessing,
                "Audio-processing support was not parsed."
            )
            try expect(
                web.propertyDefinitions.count == 4,
                "Web property definitions were not retained."
            )
            let qualityDefinition = web.propertyDefinitions.first {
                $0.name == "quality"
            }
            try expect(
                qualityDefinition?.kind == .slider
                    && qualityDefinition?.minimum == 0
                    && qualityDefinition?.maximum == 100
                    && qualityDefinition?.step == 5,
                "Slider metadata was not parsed."
            )
            let themeDefinition = web.propertyDefinitions.first {
                $0.name == "theme"
            }
            try expect(
                themeDefinition?.options.map(\.value)
                    == [.string("light"), .string("dark")],
                "Combo options were not parsed."
            )
            let overrideJSON = web.userPropertyUpdateJSON([
                "quality": .number(45),
                "unknown": .string("ignored")
            ])
            let overrideObject = try JSONSerialization.jsonObject(
                with: try expectData(overrideJSON)
            ) as? [String: [String: Any]]
            try expect(
                overrideObject?["quality"]?["value"] as? Int == 45
                    && overrideObject?["unknown"] == nil,
                "Property updates were not scoped to known definitions."
            )

            let sceneProjectURL = temporaryRoot.appendingPathComponent("scene-project")
            try makeDirectory(sceneProjectURL)
            try Data().write(to: sceneProjectURL.appendingPathComponent("scene.pkg"))
            try writeJSON([
                "title": "Supported Scene",
                "type": "Scene",
                "file": "scene.json"
            ], to: sceneProjectURL.appendingPathComponent("project.json"))

            let scene = try WallpaperProjectLoader.load(
                manifestURL: sceneProjectURL.appendingPathComponent("project.json")
            )
            try expect(scene.kind == .scene, "Scene project type was not parsed.")
            try expect(
                scene.entryURL == sceneProjectURL.appendingPathComponent("scene.pkg"),
                "Scene package fallback was not resolved."
            )
            try expect(scene.isSupported, "Scene project should be supported.")

            let applicationProjectURL = temporaryRoot
                .appendingPathComponent("application-project")
            try makeDirectory(applicationProjectURL)
            try Data().write(
                to: applicationProjectURL.appendingPathComponent("wallpaper.exe")
            )
            try writeJSON([
                "title": "Unsupported Application",
                "type": "application",
                "file": "wallpaper.exe"
            ], to: applicationProjectURL.appendingPathComponent("project.json"))

            let malformedProjectURL = temporaryRoot.appendingPathComponent("malformed")
            try makeDirectory(malformedProjectURL)
            try Data("{not-json".utf8).write(
                to: malformedProjectURL.appendingPathComponent("project.json")
            )

            let scan = WallpaperProjectLoader.scan(rootURL: temporaryRoot)
            try expect(scan.projects.count == 4, "Scanner should return four valid manifests.")
            try expect(
                scan.supportedProjects.map(\.title)
                    == ["Local Web", "Ocean Video", "Supported Scene"],
                "Scanner did not sort or classify compatible projects correctly."
            )
            try expect(
                scan.unsupportedProjects.map(\.title) == ["Unsupported Application"],
                "Application project should be retained as unsupported."
            )
            try expect(scan.issues.count == 1, "Malformed manifest should be reported once.")

            let packageURL = temporaryRoot.appendingPathComponent("format-test.pkg")
            let packageData = makeScenePackage(entries: [
                ("scene.json", Data("{\"version\":1}".utf8)),
                ("materials/test.bin", Data([1, 2, 3, 4]))
            ])
            try packageData.write(to: packageURL)
            let archive = try ScenePackageArchive(url: packageURL)
            try expect(archive.version == "PKGV0018", "Scene package version was not read.")
            try expect(
                archive.names == ["scene.json", "materials/test.bin"],
                "Scene package index was not preserved."
            )
            let testAsset = try archive.data(named: "materials/test.bin")
            try expect(
                testAsset == Data([1, 2, 3, 4]),
                "Scene package payload was not read from its indexed offset."
            )

            let unsafePackageURL = temporaryRoot
                .appendingPathComponent("unsafe-format-test.pkg")
            try makeScenePackage(entries: [
                ("../outside", Data([1]))
            ]).write(to: unsafePackageURL)
            do {
                _ = try ScenePackageArchive(url: unsafePackageURL)
                throw TestFailure.assertion(
                    "Scene package traversal path should be rejected."
                )
            } catch SceneWallpaperError.invalidPackage {
                // Expected.
            }

            let onePixelPNG = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
            let texture = try SceneTexture(
                data: makeEmbeddedImageTexture(onePixelPNG)
            )
            let decodedImage = try texture.makeImage()
            try expect(
                decodedImage.width == 1 && decodedImage.height == 1,
                "Embedded scene texture image was not decoded."
            )

            let escapedProjectURL = temporaryRoot.appendingPathComponent("escaped")
            try makeDirectory(escapedProjectURL)
            try Data().write(to: temporaryRoot.appendingPathComponent("outside.mp4"))
            try writeJSON([
                "title": "Unsafe",
                "type": "video",
                "file": "../outside.mp4"
            ], to: escapedProjectURL.appendingPathComponent("project.json"))

            do {
                _ = try WallpaperProjectLoader.load(
                    manifestURL: escapedProjectURL.appendingPathComponent("project.json")
                )
                throw TestFailure.assertion("Path traversal manifest should have been rejected.")
            } catch WallpaperProjectError.unsafeRelativePath {
                // Expected.
            }

            let workshopItem = try SteamWorkshopLinkParser.parse(
                "https://steamcommunity.com/sharedfiles/filedetails/?id=987654321"
            )
            try expect(
                workshopItem.id == "987654321",
                "Workshop item ID was not parsed from an HTTPS URL."
            )
            let steamSchemeItem = try SteamWorkshopLinkParser.parse(
                "steam://url/CommunityFilePage/123456789"
            )
            try expect(
                steamSchemeItem.id == "123456789",
                "Workshop item ID was not parsed from a Steam URL."
            )
            do {
                _ = try SteamWorkshopLinkParser.parse(
                    "https://steamcommunity.com/app/431960/workshop/"
                )
                throw TestFailure.assertion("Workshop catalogue URL should be rejected.")
            } catch SteamWorkshopLinkError.catalogURL {
                // Expected.
            }
            do {
                _ = try SteamWorkshopLinkParser.parse(
                    "https://example.com/sharedfiles/filedetails/?id=123"
                )
                throw TestFailure.assertion("Non-Steam Workshop host should be rejected.")
            } catch SteamWorkshopLinkError.unsupportedHost {
                // Expected.
            }

            let managerRoot = temporaryRoot.appendingPathComponent("manager's root")
            let isolatedWorkshopRoot = managerRoot
                .appendingPathComponent(
                    "SteamCMD/steamapps/workshop/content/431960",
                    isDirectory: true
                )
            let manager = SteamWorkshopManager(
                rootURL: managerRoot,
                workshopRootURL: isolatedWorkshopRoot
            )
            try makeDirectory(manager.steamCMDDirectoryURL)
            let stubSteamCMD = """
            #!/bin/zsh
            set -eu
            item_dir="$PWD/steamapps/workshop/content/431960/987654321"
            mkdir -p "$item_dir"
            printf '{"title":"Stub Download","type":"video","file":"wallpaper.mp4"}' \
              > "$item_dir/project.json"
            : > "$item_dir/wallpaper.mp4"
            exit 0
            """
            try stubSteamCMD.write(
                to: manager.steamCMDExecutableURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: manager.steamCMDExecutableURL.path
            )
            try expect(manager.isSteamCMDInstalled, "SteamCMD installation was not detected.")
            try expect(
                SteamWorkshopManager().workshopRootURL.path.hasSuffix(
                    "Library/Application Support/Steam/steamapps/workshop/content/431960"
                ),
                "Production Workshop root should use Steam's macOS library."
            )

            let downloadJob = try manager.prepareDownload(
                itemID: workshopItem.id,
                accountName: "livewall_test"
            )
            let commandScript = try String(contentsOf: downloadJob.scriptURL, encoding: .utf8)
            try expect(
                commandScript.contains("+workshop_download_item 431960 '987654321' validate"),
                "Generated command does not lock the download to Wallpaper Engine."
            )
            try expect(
                commandScript.contains("+login 'livewall_test'"),
                "Generated command does not contain the validated account name."
            )
            try expect(
                commandScript.contains("manager'\\''s root"),
                "Generated command did not safely quote an apostrophe in its path."
            )

            let standardInput = Pipe()
            let standardOutput = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [downloadJob.scriptURL.path]
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = standardOutput
            try process.run()
            standardInput.fileHandleForWriting.write(Data("x".utf8))
            standardInput.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let processOutputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let processOutput = String(data: processOutputData, encoding: .utf8) ?? ""
            try expect(
                process.terminationStatus == 0,
                """
                Generated interactive download job did not exit successfully. \
                Output: \(processOutput)
                """
            )
            try expect(
                FileManager.default.fileExists(
                    atPath: downloadJob.successMarkerURL.path
                ),
                "Generated download job did not create its success marker."
            )
            try expect(
                manager.existingProject(itemID: workshopItem.id)?.title == "Stub Download",
                "Generated download job did not create an importable project."
            )

            let loginUsersURL = temporaryRoot.appendingPathComponent("loginusers.vdf")
            let loginUsersFixture = """
            "users"
            {
                "111"
                {
                    "AccountName"      "older_account"
                    "MostRecent"       "0"
                    "Timestamp"        "100"
                }
                "222"
                {
                    "AccountName"      "recent_account"
                    "MostRecent"       "1"
                    "Timestamp"        "200"
                }
            }
            """
            try loginUsersFixture.write(
                to: loginUsersURL,
                atomically: true,
                encoding: .utf8
            )
            try expect(
                manager.detectedSteamAccountName(loginUsersURL: loginUsersURL)
                    == "recent_account",
                "Most-recent Steam account name was not detected."
            )
            do {
                _ = try manager.prepareDownload(
                    itemID: workshopItem.id,
                    accountName: "user; touch bad"
                )
                throw TestFailure.assertion("Unsafe Steam account name should be rejected.")
            } catch SteamWorkshopManagerError.invalidAccountName {
                // Expected.
            }
            manager.cleanup(job: downloadJob)
            try expect(
                !FileManager.default.fileExists(atPath: downloadJob.scriptURL.path),
                "Download job cleanup did not remove its command script."
            )

            let privatePath = NSHomeDirectory() + "/private/wallpaper/project.json"
            try expect(
                LiveWallDiagnostics.redactedPath(privatePath)
                    == "~/private/wallpaper/project.json",
                "Diagnostics should redact the user's home directory."
            )
            let diagnosticReport = LiveWallDiagnostics.makeReport(
                details: ["Project manifest": privatePath],
                includeLog: false
            )
            try expect(
                !diagnosticReport.contains(NSHomeDirectory())
                    && diagnosticReport.contains("~/private/wallpaper/project.json"),
                "Diagnostic reports should not expose the user's home path."
            )

            print("WallpaperProjectLoaderTests: all checks passed")
        } catch {
            fputs("WallpaperProjectLoaderTests failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private func expectData(_ string: String) throws -> Data {
    guard let data = string.data(using: .utf8) else {
        throw TestFailure.assertion("Expected valid UTF-8 JSON.")
    }
    return data
}
