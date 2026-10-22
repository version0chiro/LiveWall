import AppKit

enum SmokeTestRunner {
    static func runAudioAnalyzer() -> Int32 {
        let analyzer = SystemAudioSpectrumCapture()
        let sampleRate = 48_000.0
        let frequency = 440.0
        let samples = (0..<1024).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        let spectrum = analyzer.analyzeForTesting(samples: samples)
        guard spectrum.count == 128,
              spectrum.allSatisfy(\.isFinite),
              spectrum.max() ?? 0 > 0.1 else {
            fputs(
                "LiveWall audio analyzer smoke test failed\n",
                stderr
            )
            return 1
        }
        print("LiveWall audio analyzer smoke test passed: 128 finite bands")
        return 0
    }

    static func runPropertyEditor(manifestPath: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        do {
            let project = try WallpaperProjectLoader.load(
                manifestURL: URL(fileURLWithPath: manifestPath)
            )
            guard project.kind == .web,
                  !project.propertyDefinitions.isEmpty else {
                fputs(
                    "LiveWall property editor smoke test failed: no web properties\n",
                    stderr
                )
                return 1
            }
            let editor = WallpaperPropertyEditor(
                project: project,
                values: project.defaultPropertyValues,
                onChange: { _ in }
            )
            editor.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print(
                    "LiveWall property editor smoke test passed: \(project.propertyDefinitions.count) controls"
                )
                editor.close()
                app.terminate(nil)
            }
            app.run()
            withExtendedLifetime(editor) {}
            return 0
        } catch {
            fputs(
                "LiveWall property editor smoke test failed: \(error.localizedDescription)\n",
                stderr
            )
            return 1
        }
    }

    static func runSteamSetup() -> Int32 {
        let manager = SteamWorkshopManager()
        guard manager.isSteamCMDInstalled else {
            fputs(
                "LiveWall Steam setup test failed: SteamCMD is not installed\n",
                stderr
            )
            return 1
        }
        guard let accountName = manager.detectedSteamAccountName(),
              SteamWorkshopManager.isValidAccountName(accountName) else {
            fputs(
                "LiveWall Steam setup test failed: no valid recent Steam account was detected\n",
                stderr
            )
            return 1
        }
        print(
            "LiveWall Steam setup test passed: SteamCMD installed, account detected (redacted, \(accountName.count) characters)"
        )
        return 0
    }

    static func runWorkshopLink(rawLink: String, accountName: String) -> Int32 {
        do {
            let item = try SteamWorkshopLinkParser.parse(rawLink)
            let manager = SteamWorkshopManager()
            guard manager.isSteamCMDInstalled else {
                fputs(
                    "LiveWall Workshop smoke test failed: SteamCMD is not installed\n",
                    stderr
                )
                return 1
            }
            let job = try manager.prepareDownload(
                itemID: item.id,
                accountName: accountName
            )
            defer { manager.cleanup(job: job) }

            let script = try String(contentsOf: job.scriptURL, encoding: .utf8)
            guard script.contains(
                "+workshop_download_item \(SteamWorkshopManager.wallpaperEngineAppID) '\(item.id)' validate"
            ) else {
                fputs(
                    "LiveWall Workshop smoke test failed: generated command is incorrect\n",
                    stderr
                )
                return 1
            }
            print(
                "LiveWall Workshop smoke test passed: item \(item.id), SteamCMD installed"
            )
            return 0
        } catch {
            fputs(
                "LiveWall Workshop smoke test failed: \(error.localizedDescription)\n",
                stderr
            )
            return 1
        }
    }

    static func run(manifestPath: String, interactive: Bool = false) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        do {
            let project = try WallpaperProjectLoader.load(
                manifestURL: URL(fileURLWithPath: manifestPath)
            )
            guard project.isSupported else {
                fputs(
                    "LiveWall smoke test failed: unsupported \(project.kind.displayName) project\n",
                    stderr
                )
                return 1
            }

            let engine = WallpaperEngine()
            var exitCode: Int32 = 1
            var didFinish = false
            engine.onContentReady = { result in
                guard !didFinish else { return }
                didFinish = true
                switch result {
                case .success:
                    if interactive && !engine.hasAppliedInteractiveMode {
                        fputs(
                            "LiveWall smoke test failed: interactive window state was not applied\n",
                            stderr
                        )
                        app.terminate(nil)
                    } else if interactive {
                        engine.verifyWebHostCompatibility { probeResult in
                            switch probeResult {
                            case .success:
                                print(
                                    "LiveWall smoke test passed: \(project.title) [\(project.kind.displayName), interactive mode, properties, audio and media host]"
                                )
                                exitCode = 0
                            case .failure(let error):
                                fputs(
                                    "LiveWall smoke test failed: \(error.localizedDescription)\n",
                                    stderr
                                )
                            }
                            app.terminate(nil)
                        }
                        return
                    } else {
                        let suffix = interactive ? ", interactive mode" : ""
                        print(
                            "LiveWall smoke test passed: \(project.title) [\(project.kind.displayName)\(suffix)]"
                        )
                        exitCode = 0
                    }
                case .failure(let error):
                    fputs("LiveWall smoke test failed: \(error.localizedDescription)\n", stderr)
                }
                app.terminate(nil)
            }

            try engine.setWallpaper(project: project)
            if interactive {
                guard engine.canEnableInteraction else {
                    fputs(
                        "LiveWall smoke test failed: project is not an interactive web wallpaper\n",
                        stderr
                    )
                    return 1
                }
                engine.setInteractionMode(.holdOption)
                guard !engine.isInteractionEnabled else {
                    fputs(
                        "LiveWall smoke test failed: Widget Mode covered icons before Option was active\n",
                        stderr
                    )
                    return 1
                }
                engine.setHoldOptionActive(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !didFinish else { return }
                didFinish = true
                fputs("LiveWall smoke test failed: wallpaper did not become ready\n", stderr)
                app.terminate(nil)
            }
            app.run()
            withExtendedLifetime(engine) {}
            return exitCode
        } catch {
            fputs("LiveWall smoke test failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
