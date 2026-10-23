import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = WallpaperEngine()
    private let workshopManager = SteamWorkshopManager()
    private var statusItem: NSStatusItem!
    private var libraryScan: WallpaperLibraryScan?
    private var activeWorkshopDownload: SteamWorkshopDownloadJob?
    private var workshopDownloadTimer: Timer?
    private var holdInteractionTimer: Timer?
    private var optionInteractionIsActive = false
    private var propertyEditor: WallpaperPropertyEditor?
    private let audioSpectrumCapture = SystemAudioSpectrumCapture()
    private let nowPlayingMonitor = NowPlayingMonitor()
    private var audioIntegrationEnabled = false
    private var mediaIntegrationEnabled = false

    private let lastURLKey = "LiveWall.lastWallpaperURL"
    private let lastProjectKey = "LiveWall.lastWallpaperEngineManifest"
    private let lastSelectionKindKey = "LiveWall.lastSelectionKind"
    private let libraryRootKey = "LiveWall.wallpaperEngineLibraryRoot"
    private let pauseFullscreenKey = "LiveWall.pauseWhenFullscreen"
    private let pauseBatteryKey = "LiveWall.pauseOnBattery"
    private let gravityKey = "LiveWall.videoGravity"
    private let steamAccountNameKey = "LiveWall.steamAccountName"
    private let propertyOverridesKey = "LiveWall.webPropertyOverrides"
    private let networkPermissionsKey = "LiveWall.webNetworkPermissions"
    private let audioIntegrationKey = "LiveWall.audioIntegrationEnabled"
    private let mediaIntegrationKey = "LiveWall.mediaIntegrationEnabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadPrefs()
        configureHostIntegrations()
        setupStatusItem()
        restoreLibrary()
        restoreLastWallpaper()
        startEnabledHostIntegrations()
        startHoldInteractionMonitor()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reapplyPolicy),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if CommandLine.arguments.contains("--smoke-test-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("LiveWall smoke test passed: menu-bar startup")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "photo.on.rectangle.angled",
                accessibilityDescription: "LiveWall"
            )
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(actionItem(
            title: "Choose Video…",
            action: #selector(chooseVideo),
            keyEquivalent: "o"
        ))
        menu.addItem(actionItem(
            title: "Import Wallpaper Engine Folder…",
            action: #selector(chooseWallpaperEngineFolder),
            keyEquivalent: "i"
        ))
        menu.addItem(actionItem(
            title: "Download from Steam Workshop Link…",
            action: #selector(downloadFromSteamWorkshopLink),
            keyEquivalent: "d"
        ))

        if let activeWorkshopDownload {
            let item = NSMenuItem(
                title: "Downloading Workshop Item \(activeWorkshopDownload.itemID)…",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        if libraryScan != nil {
            menu.addItem(actionItem(
                title: "Rescan Imported Library",
                action: #selector(rescanLibrary),
                keyEquivalent: ""
            ))
            menu.addItem(makeLibraryMenuItem())
        }

        if let currentDisplayName = engine.currentDisplayName {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Playing: \(currentDisplayName)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let widgetMode = actionItem(
            title: "Widget Mode (icons visible; hold Option)",
            action: #selector(toggleWidgetMode),
            keyEquivalent: "w"
        )
        widgetMode.keyEquivalentModifierMask = [.control, .option]
        widgetMode.state = engine.interactionMode == .holdOption ? .on : .off
        widgetMode.isEnabled = engine.canEnableInteraction
        menu.addItem(widgetMode)

        let interaction = actionItem(
            title: "Always Interactive (covers desktop icons)",
            action: #selector(toggleAlwaysInteraction),
            keyEquivalent: "i"
        )
        interaction.keyEquivalentModifierMask = [.control, .option]
        interaction.state = engine.interactionMode == .always ? .on : .off
        interaction.isEnabled = engine.canEnableInteraction
        menu.addItem(interaction)

        if engine.interactionMode == .holdOption {
            let hint = NSMenuItem(
                title: "Click the desktop, then hold Option to interact",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        } else if engine.interactionMode == .always {
            let hint = NSMenuItem(
                title: "Turn this off to use desktop icons",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let properties = actionItem(
            title: "Wallpaper Properties…",
            action: #selector(editWallpaperProperties),
            keyEquivalent: ","
        )
        properties.isEnabled = engine.currentProject?.kind == .web
            && !(engine.currentProject?.propertyDefinitions.isEmpty ?? true)
        menu.addItem(properties)

        let network = actionItem(
            title: "Allow Internet for This Wallpaper",
            action: #selector(toggleNetworkAccess),
            keyEquivalent: ""
        )
        network.state = engine.allowsNetworkAccess ? .on : .off
        network.isEnabled = engine.currentProject?.kind == .web
        menu.addItem(network)

        let audio = actionItem(
            title: "System Audio for Visualizers",
            action: #selector(toggleAudioIntegration),
            keyEquivalent: ""
        )
        audio.state = audioIntegrationEnabled ? .on : .off
        audio.isEnabled = engine.currentProject?.kind == .web
        menu.addItem(audio)

        let media = actionItem(
            title: "Music & Spotify Media Widgets",
            action: #selector(toggleMediaIntegration),
            keyEquivalent: ""
        )
        media.state = mediaIntegrationEnabled ? .on : .off
        media.isEnabled = engine.currentProject?.kind == .web
        menu.addItem(media)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Pause", action: #selector(pause), keyEquivalent: "p"))
        menu.addItem(actionItem(title: "Resume", action: #selector(resume), keyEquivalent: "r"))

        menu.addItem(.separator())

        let fill = actionItem(
            title: "Fill Screen (crop)",
            action: #selector(setFill),
            keyEquivalent: ""
        )
        fill.state = engine.options.videoGravity == .resizeAspectFill ? .on : .off
        menu.addItem(fill)

        let fit = actionItem(
            title: "Fit Screen (letterbox)",
            action: #selector(setFit),
            keyEquivalent: ""
        )
        fit.state = engine.options.videoGravity == .resizeAspect ? .on : .off
        menu.addItem(fit)

        menu.addItem(.separator())

        let fullscreenPause = actionItem(
            title: "Pause When App is Fullscreen",
            action: #selector(toggleFullscreenPause),
            keyEquivalent: ""
        )
        fullscreenPause.state = engine.options.pauseWhenFullscreen ? .on : .off
        menu.addItem(fullscreenPause)

        let batteryPause = actionItem(
            title: "Pause on Battery",
            action: #selector(toggleBatteryPause),
            keyEquivalent: ""
        )
        batteryPause.state = engine.options.pauseOnBattery ? .on : .off
        menu.addItem(batteryPause)

        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "Quit LiveWall",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func makeLibraryMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(
            title: "Wallpaper Engine Library",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: "Wallpaper Engine Library")
        let supported = libraryScan?.supportedProjects ?? []
        let unsupported = libraryScan?.unsupportedProjects ?? []

        if supported.isEmpty {
            let empty = NSMenuItem(
                title: "No compatible video or web projects",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for project in supported.prefix(200) {
                let item = actionItem(
                    title: "\(project.title)  [\(project.kind.displayName)]",
                    action: #selector(selectWallpaperEngineProject(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = project.manifestURL.path
                item.state = engine.currentProject?.manifestURL == project.manifestURL ? .on : .off
                submenu.addItem(item)
            }
            if supported.count > 200 {
                let remaining = NSMenuItem(
                    title: "\(supported.count - 200) more projects not shown",
                    action: nil,
                    keyEquivalent: ""
                )
                remaining.isEnabled = false
                submenu.addItem(remaining)
            }
        }

        if !unsupported.isEmpty {
            submenu.addItem(.separator())
            let summary = NSMenuItem(
                title: "\(unsupported.count) unsupported application/unknown projects",
                action: nil,
                keyEquivalent: ""
            )
            summary.isEnabled = false
            submenu.addItem(summary)
        }

        if let libraryScan, !libraryScan.issues.isEmpty {
            let summary = NSMenuItem(
                title: "\(libraryScan.issues.count) invalid projects skipped",
                action: nil,
                keyEquivalent: ""
            )
            summary.isEnabled = false
            submenu.addItem(summary)
        }

        parent.submenu = submenu
        return parent
    }

    private func actionItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - Selection

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        }
        panel.prompt = "Set Wallpaper"
        if panel.runModal() == .OK, let url = panel.url {
            setVideoWallpaper(url)
        }
    }

    @objc private func chooseWallpaperEngineFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Import"
        panel.message = """
        Choose a Wallpaper Engine project folder or the Steam Workshop folder \
        containing project subfolders.
        """
        if panel.runModal() == .OK, let url = panel.url {
            scanLibrary(at: url, reportResult: true)
        }
    }

    @objc private func downloadFromSteamWorkshopLink() {
        var suggestedLink = ""
        if let clipboardValue = NSPasteboard.general.string(forType: .string),
           (try? SteamWorkshopLinkParser.parse(clipboardValue)) != nil {
            suggestedLink = clipboardValue
        }

        let savedAccount = UserDefaults.standard
            .string(forKey: steamAccountNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedAccount: String
        if let savedAccount,
           SteamWorkshopManager.isValidAccountName(savedAccount) {
            suggestedAccount = savedAccount
        } else {
            suggestedAccount = workshopManager.detectedSteamAccountName() ?? ""
        }

        let prompt = WorkshopDownloadPrompt(
            initialLink: suggestedLink,
            initialAccountName: suggestedAccount
        )
        guard let response = prompt.run() else { return }

        do {
            let item = try SteamWorkshopLinkParser.parse(response.link)
            UserDefaults.standard.set(
                response.accountName,
                forKey: steamAccountNameKey
            )
            try startWorkshopDownload(
                item: item,
                accountName: response.accountName
            )
        } catch {
            showAlert(
                title: "Could Not Start Download",
                message: error.localizedDescription
            )
        }
    }

    @objc private func rescanLibrary() {
        guard let path = UserDefaults.standard.string(forKey: libraryRootKey) else { return }
        scanLibrary(at: URL(fileURLWithPath: path), reportResult: true)
    }

    @objc private func selectWallpaperEngineProject(_ sender: NSMenuItem) {
        guard let manifestPath = sender.representedObject as? String else { return }
        do {
            let project = try WallpaperProjectLoader.load(
                manifestURL: URL(fileURLWithPath: manifestPath)
            )
            try setWallpaperEngineProject(project)
        } catch {
            showAlert(
                title: "Could Not Load Wallpaper",
                message: error.localizedDescription
            )
        }
    }

    private func scanLibrary(at rootURL: URL, reportResult: Bool) {
        let scan = WallpaperProjectLoader.scan(rootURL: rootURL)
        libraryScan = scan
        UserDefaults.standard.set(rootURL.path, forKey: libraryRootKey)
        rebuildMenu()

        if reportResult, scan.supportedProjects.count == 1,
           let project = scan.supportedProjects.first {
            do {
                try setWallpaperEngineProject(project)
                return
            } catch {
                showAlert(
                    title: "Could Not Load Wallpaper",
                    message: error.localizedDescription
                )
                return
            }
        }

        guard reportResult else { return }
        if scan.supportedProjects.isEmpty {
            var details = """
            No compatible projects were found. LiveWall currently supports \
            Wallpaper Engine video, web and compatible 2D scene projects.
            """
            if let firstIssue = scan.issues.first {
                details += "\n\nFirst skipped item: \(firstIssue.message)"
            }
            showAlert(title: "No Compatible Wallpapers", message: details)
        } else {
            showAlert(
                title: "Library Imported",
                message: """
                Found \(scan.supportedProjects.count) compatible project(s) and \
                \(scan.unsupportedProjects.count) unsupported project(s). Choose \
                one from the Wallpaper Engine Library menu.
                """
            )
        }
    }

    private func startWorkshopDownload(
        item: SteamWorkshopItem,
        accountName: String
    ) throws {
        if let existingProject = workshopManager.existingProject(itemID: item.id) {
            try importDownloadedWorkshopProject(existingProject)
            showAlert(
                title: "Wallpaper Already Downloaded",
                message: "\(existingProject.title) was found locally and imported."
            )
            return
        }

        let job = try workshopManager.prepareDownload(
            itemID: item.id,
            accountName: accountName
        )
        guard NSWorkspace.shared.open(job.scriptURL) else {
            workshopManager.cleanup(job: job)
            throw SteamWorkshopManagerError.couldNotPrepareDownload(
                "macOS could not open the SteamCMD job in Terminal"
            )
        }

        activeWorkshopDownload = job
        workshopDownloadTimer?.invalidate()
        workshopDownloadTimer = Timer.scheduledTimer(
            timeInterval: 2,
            target: self,
            selector: #selector(checkWorkshopDownload),
            userInfo: nil,
            repeats: true
        )
        rebuildMenu()
    }

    @objc private func checkWorkshopDownload() {
        guard let job = activeWorkshopDownload else {
            workshopDownloadTimer?.invalidate()
            workshopDownloadTimer = nil
            return
        }

        if FileManager.default.fileExists(atPath: job.successMarkerURL.path),
           FileManager.default.fileExists(atPath: job.manifestURL.path) {
            finishWorkshopDownload(job: job)
            return
        }
        if FileManager.default.fileExists(atPath: job.failureMarkerURL.path) {
            let statusText = try? String(
                contentsOf: job.failureMarkerURL,
                encoding: .utf8
            )
            let status = statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
            stopMonitoringWorkshopDownload(job: job)
            showAlert(
                title: "Steam Workshop Download Failed",
                message: """
                SteamCMD exited\(status.map { " with status \($0)" } ?? ""). \
                Review the Terminal output for the exact Steam or Steam Guard error.
                """
            )
            return
        }
        if Date().timeIntervalSince(job.createdAt) > 30 * 60 {
            stopMonitoringWorkshopDownload(job: job)
            showAlert(
                title: "Steam Workshop Download Timed Out",
                message: """
                LiveWall stopped waiting after 30 minutes. The Terminal download \
                may still be running; you can import its folder manually afterward.
                """
            )
        }
    }

    private func finishWorkshopDownload(job: SteamWorkshopDownloadJob) {
        do {
            let project = try WallpaperProjectLoader.load(manifestURL: job.manifestURL)
            try importDownloadedWorkshopProject(project)
            stopMonitoringWorkshopDownload(job: job)
            if project.isSupported {
                showAlert(
                    title: "Wallpaper Downloaded",
                    message: "\(project.title) was imported and is now playing."
                )
            } else {
                showAlert(
                    title: "Wallpaper Downloaded but Unsupported",
                    message: """
                    \(project.title) is a \(project.kind.displayName) wallpaper. \
                    LiveWall currently plays video, web and compatible 2D scene \
                    projects.
                    """
                )
            }
        } catch {
            stopMonitoringWorkshopDownload(job: job)
            showAlert(
                title: "Downloaded Project Could Not Be Imported",
                message: error.localizedDescription
            )
        }
    }

    private func importDownloadedWorkshopProject(_ project: WallpaperProject) throws {
        libraryScan = WallpaperProjectLoader.scan(rootURL: workshopManager.workshopRootURL)
        UserDefaults.standard.set(
            workshopManager.workshopRootURL.path,
            forKey: libraryRootKey
        )
        if project.isSupported {
            try setWallpaperEngineProject(project)
        } else {
            rebuildMenu()
        }
    }

    private func stopMonitoringWorkshopDownload(job: SteamWorkshopDownloadJob) {
        workshopDownloadTimer?.invalidate()
        workshopDownloadTimer = nil
        activeWorkshopDownload = nil
        workshopManager.cleanup(job: job)
        rebuildMenu()
    }

    private func setVideoWallpaper(_ url: URL) {
        disableInteractionIfNeeded()
        propertyEditor?.close()
        propertyEditor = nil
        audioSpectrumCapture.stop()
        nowPlayingMonitor.stop()
        engine.setWallpaper(url: url)
        let defaults = UserDefaults.standard
        defaults.set("video", forKey: lastSelectionKindKey)
        defaults.set(url.path, forKey: lastURLKey)
        rebuildMenu()
    }

    private func setWallpaperEngineProject(_ project: WallpaperProject) throws {
        disableInteractionIfNeeded()
        propertyEditor?.close()
        propertyEditor = nil
        if project.kind != .web {
            audioSpectrumCapture.stop()
            nowPlayingMonitor.stop()
        }
        let values = propertyValues(for: project)
        try engine.setWallpaper(
            project: project,
            userPropertiesJSON: project.userPropertiesJSON(
                overrides: preparedPropertyValues(values, for: project)
            ),
            allowsNetworkAccess: networkAccessAllowed(for: project)
        )
        startEnabledHostIntegrations()
        let defaults = UserDefaults.standard
        defaults.set("project", forKey: lastSelectionKindKey)
        defaults.set(project.manifestURL.path, forKey: lastProjectKey)
        rebuildMenu()
    }

    // MARK: - Playback actions

    @objc private func toggleWidgetMode() {
        guard engine.canEnableInteraction else { return }
        let nextMode: WallpaperInteractionMode =
            engine.interactionMode == .holdOption ? .off : .holdOption
        engine.setInteractionMode(nextMode)
        optionInteractionIsActive = false
        rebuildMenu()
        DispatchQueue.main.async {
            NSApp.deactivate()
        }
    }

    @objc private func toggleAlwaysInteraction() {
        guard engine.canEnableInteraction else { return }
        if engine.interactionMode == .always {
            engine.setInteractionMode(.off)
            rebuildMenu()
            DispatchQueue.main.async {
                NSApp.deactivate()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            engine.setInteractionMode(.always)
            rebuildMenu()
        }
    }

    @objc private func editWallpaperProperties() {
        guard let project = engine.currentProject,
              project.kind == .web else {
            return
        }
        let editor = WallpaperPropertyEditor(
            project: project,
            values: propertyValues(for: project)
        ) { [weak self] values in
            guard let self else { return }
            let previousValues = self.propertyValues(for: project)
            let changes = values.filter {
                previousValues[$0.key] != $0.value
            }
            self.persistPropertyValues(values, for: project)
            let prepared = self.preparedPropertyValues(changes, for: project)
            self.engine.updateUserProperties(
                json: project.userPropertyUpdateJSON(prepared)
            )
        }
        propertyEditor = editor
        editor.show()
    }

    @objc private func toggleNetworkAccess() {
        guard let project = engine.currentProject,
              project.kind == .web else {
            return
        }

        let allow = !engine.allowsNetworkAccess
        if allow {
            let alert = NSAlert()
            alert.messageText = "Allow Internet Access?"
            alert.informativeText = """
            This permits the current wallpaper's JavaScript to contact remote \
            servers for weather, news or other data. Only enable it for a \
            wallpaper you trust.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow and Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        persistNetworkAccess(allow, for: project)
        engine.setNetworkAccessAllowed(allow)
        rebuildMenu()
    }

    @objc private func toggleAudioIntegration() {
        audioIntegrationEnabled.toggle()
        UserDefaults.standard.set(
            audioIntegrationEnabled,
            forKey: audioIntegrationKey
        )
        if audioIntegrationEnabled {
            startAudioIntegration(showErrors: true)
        } else {
            audioSpectrumCapture.stop()
        }
        rebuildMenu()
    }

    @objc private func toggleMediaIntegration() {
        mediaIntegrationEnabled.toggle()
        UserDefaults.standard.set(
            mediaIntegrationEnabled,
            forKey: mediaIntegrationKey
        )
        if mediaIntegrationEnabled {
            nowPlayingMonitor.start()
        } else {
            nowPlayingMonitor.stop()
        }
        rebuildMenu()
    }

    @objc private func pause() {
        engine.pause()
    }

    @objc private func resume() {
        engine.resume()
    }

    @objc private func setFill() {
        engine.options.videoGravity = .resizeAspectFill
        persistGravity()
        engine.reload()
        rebuildMenu()
    }

    @objc private func setFit() {
        engine.options.videoGravity = .resizeAspect
        persistGravity()
        engine.reload()
        rebuildMenu()
    }

    @objc private func toggleFullscreenPause() {
        engine.options.pauseWhenFullscreen.toggle()
        UserDefaults.standard.set(
            engine.options.pauseWhenFullscreen,
            forKey: pauseFullscreenKey
        )
        engine.applyPolicy()
        rebuildMenu()
    }

    @objc private func toggleBatteryPause() {
        engine.options.pauseOnBattery.toggle()
        UserDefaults.standard.set(engine.options.pauseOnBattery, forKey: pauseBatteryKey)
        engine.applyPolicy()
        rebuildMenu()
    }

    @objc private func reapplyPolicy() {
        engine.applyPolicy()
    }

    @objc private func quit() {
        workshopDownloadTimer?.invalidate()
        holdInteractionTimer?.invalidate()
        audioSpectrumCapture.stop()
        nowPlayingMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Preferences

    private func persistGravity() {
        UserDefaults.standard.set(
            engine.options.videoGravity == .resizeAspect ? "fit" : "fill",
            forKey: gravityKey
        )
    }

    private func disableInteractionIfNeeded() {
        guard engine.interactionMode != .off else { return }
        engine.setInteractionMode(.off)
        optionInteractionIsActive = false
        DispatchQueue.main.async {
            NSApp.deactivate()
        }
    }

    private func startHoldInteractionMonitor() {
        holdInteractionTimer?.invalidate()
        holdInteractionTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            self?.updateHoldInteractionState()
        }
    }

    private func updateHoldInteractionState() {
        guard engine.interactionMode == .holdOption else {
            if optionInteractionIsActive {
                optionInteractionIsActive = false
                engine.setHoldOptionActive(false)
                NSApp.deactivate()
            }
            return
        }

        let frontmostBundleID =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isDesktopContext = frontmostBundleID == "com.apple.finder"
            || frontmostBundleID == Bundle.main.bundleIdentifier
        let shouldInteract = isDesktopContext
            && NSEvent.modifierFlags.contains(.option)
        guard shouldInteract != optionInteractionIsActive else { return }

        optionInteractionIsActive = shouldInteract
        if shouldInteract {
            NSApp.activate(ignoringOtherApps: true)
            engine.setHoldOptionActive(true)
        } else {
            engine.setHoldOptionActive(false)
            NSApp.deactivate()
        }
    }

    private func configureHostIntegrations() {
        audioSpectrumCapture.onSpectrum = { [weak self] samples in
            self?.engine.sendAudioSpectrum(samples)
        }
        nowPlayingMonitor.onUpdate = { [weak self] snapshot in
            self?.engine.sendMediaSnapshot(snapshot)
        }
    }

    private func startEnabledHostIntegrations() {
        guard engine.currentProject?.kind == .web else { return }
        if audioIntegrationEnabled {
            startAudioIntegration(showErrors: false)
        }
        if mediaIntegrationEnabled {
            nowPlayingMonitor.start()
        }
    }

    private func startAudioIntegration(showErrors: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioSpectrumCapture.start()
            } catch {
                self.audioIntegrationEnabled = false
                UserDefaults.standard.set(false, forKey: self.audioIntegrationKey)
                self.rebuildMenu()
                if showErrors {
                    self.showAlert(
                        title: "System Audio Is Unavailable",
                        message: """
                        \(error.localizedDescription)

                        Enable Screen & System Audio Recording for LiveWall in \
                        System Settings → Privacy & Security, then try again.
                        """
                    )
                }
            }
        }
    }

    private func propertyValues(
        for project: WallpaperProject
    ) -> [String: WallpaperPropertyValue] {
        var values = project.defaultPropertyValues
        guard let allOverrides = UserDefaults.standard.dictionary(
            forKey: propertyOverridesKey
        ),
        let saved = allOverrides[project.manifestURL.path]
            as? [String: Any] else {
            return values
        }

        for definition in project.propertyDefinitions {
            if let rawValue = saved[definition.name],
               let value = WallpaperPropertyValue(jsonValue: rawValue) {
                values[definition.name] = value
            }
        }
        return values
    }

    private func persistPropertyValues(
        _ values: [String: WallpaperPropertyValue],
        for project: WallpaperProject
    ) {
        var allOverrides = UserDefaults.standard.dictionary(
            forKey: propertyOverridesKey
        ) ?? [:]
        allOverrides[project.manifestURL.path] = values.mapValues(\.jsonValue)
        UserDefaults.standard.set(allOverrides, forKey: propertyOverridesKey)
    }

    private func preparedPropertyValues(
        _ values: [String: WallpaperPropertyValue],
        for project: WallpaperProject
    ) -> [String: WallpaperPropertyValue] {
        var prepared = values
        for definition in project.propertyDefinitions
        where definition.kind == .file {
            guard case .string(let path) = values[definition.name],
                  !path.isEmpty,
                  !path.hasPrefix("data:"),
                  !path.hasPrefix("http:"),
                  !path.hasPrefix("https:") else {
                continue
            }

            let url = URL(fileURLWithPath: path)
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue <= 25 * 1024 * 1024,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                continue
            }
            let mimeType = UTType(filenameExtension: url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            prepared[definition.name] = .string(
                "data:\(mimeType);base64,\(data.base64EncodedString())"
            )
        }
        return prepared
    }

    private func networkAccessAllowed(for project: WallpaperProject) -> Bool {
        let permissions = UserDefaults.standard.dictionary(
            forKey: networkPermissionsKey
        )
        return permissions?[project.manifestURL.path] as? Bool ?? false
    }

    private func persistNetworkAccess(
        _ allowed: Bool,
        for project: WallpaperProject
    ) {
        var permissions = UserDefaults.standard.dictionary(
            forKey: networkPermissionsKey
        ) ?? [:]
        permissions[project.manifestURL.path] = allowed
        UserDefaults.standard.set(permissions, forKey: networkPermissionsKey)
    }

    private func loadPrefs() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: pauseFullscreenKey) != nil {
            engine.options.pauseWhenFullscreen = defaults.bool(forKey: pauseFullscreenKey)
        }
        engine.options.pauseOnBattery = defaults.bool(forKey: pauseBatteryKey)
        if defaults.string(forKey: gravityKey) == "fit" {
            engine.options.videoGravity = .resizeAspect
        }
        audioIntegrationEnabled = defaults.bool(forKey: audioIntegrationKey)
        mediaIntegrationEnabled = defaults.bool(forKey: mediaIntegrationKey)
    }

    private func restoreLibrary() {
        guard let path = UserDefaults.standard.string(forKey: libraryRootKey),
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        libraryScan = WallpaperProjectLoader.scan(rootURL: URL(fileURLWithPath: path))
        rebuildMenu()
    }

    private func restoreLastWallpaper() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastSelectionKindKey) == "project",
           let path = defaults.string(forKey: lastProjectKey),
           FileManager.default.fileExists(atPath: path),
           let project = try? WallpaperProjectLoader.load(
               manifestURL: URL(fileURLWithPath: path)
           ),
           project.isSupported {
            try? setWallpaperEngineProject(project)
            return
        }

        if let path = defaults.string(forKey: lastURLKey),
           FileManager.default.fileExists(atPath: path) {
            engine.setWallpaper(url: URL(fileURLWithPath: path))
            rebuildMenu()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private final class WorkshopDownloadPrompt: NSObject, NSTextFieldDelegate {
    struct Response {
        let link: String
        let accountName: String
    }

    private let alert = NSAlert()
    private let linkField: NSTextField
    private let accountField: NSTextField

    init(initialLink: String, initialAccountName: String) {
        linkField = NSTextField(string: initialLink)
        accountField = NSTextField(string: initialAccountName)
        super.init()

        linkField.placeholderString =
            "https://steamcommunity.com/sharedfiles/filedetails/?id=…"
        accountField.placeholderString = "Steam login account name"
        linkField.delegate = self
        accountField.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 106))
        let linkLabel = NSTextField(labelWithString: "Individual Workshop item link")
        linkLabel.frame = NSRect(x: 0, y: 84, width: 520, height: 18)
        linkField.frame = NSRect(x: 0, y: 56, width: 520, height: 24)
        let accountLabel = NSTextField(
            labelWithString: "Steam login account name (not email or display name)"
        )
        accountLabel.frame = NSRect(x: 0, y: 32, width: 520, height: 18)
        accountField.frame = NSRect(x: 0, y: 4, width: 520, height: 24)
        container.addSubview(linkLabel)
        container.addSubview(linkField)
        container.addSubview(accountLabel)
        container.addSubview(accountField)

        alert.messageText = "Download Wallpaper Engine Workshop Item"
        alert.informativeText = """
        LiveWall opens Valve SteamCMD in Terminal. SteamCMD—not LiveWall—will \
        ask for your password and Steam Guard code.
        """
        alert.accessoryView = container
        alert.addButton(withTitle: "Open Steam Login in Terminal")
        alert.addButton(withTitle: "Cancel")
        updateDownloadButton()
    }

    func run() -> Response? {
        alert.window.initialFirstResponder = linkField.stringValue.isEmpty
            ? linkField
            : accountField
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return Response(
            link: linkField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            accountName: accountField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }

    func controlTextDidChange(_ notification: Notification) {
        updateDownloadButton()
    }

    private func updateDownloadButton() {
        let hasValidLink = (try? SteamWorkshopLinkParser.parse(
            linkField.stringValue
        )) != nil
        let hasValidAccount = SteamWorkshopManager.isValidAccountName(
            accountField.stringValue
        )
        alert.buttons.first?.isEnabled = hasValidLink && hasValidAccount
    }
}
