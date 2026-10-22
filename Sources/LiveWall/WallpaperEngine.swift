import AppKit
import AVFoundation
import IOKit.ps

enum WallpaperInteractionMode: String {
    case off
    case holdOption
    case always
}

/// Owns a WallpaperWindow + looping player per screen, keeps them in sync with
/// display changes, and pauses playback when it would waste resources
/// (a fullscreen app is covering the desktop, or we're on battery).
final class WallpaperEngine {

    struct Options {
        var pauseWhenFullscreen: Bool = true
        var pauseOnBattery: Bool = false
        var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    }

    private var windows: [WallpaperWindow] = []
    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []

    private enum Content {
        case video(URL)
        case web(entryURL: URL, projectDirectoryURL: URL)
    }

    private var content: Content?
    private(set) var currentProject: WallpaperProject?
    private(set) var currentDisplayName: String?
    var onContentReady: ((Result<Void, Error>) -> Void)?
    var options = Options()
    private(set) var interactionMode: WallpaperInteractionMode = .off
    private(set) var allowsNetworkAccess = false
    private(set) var currentUserPropertiesJSON = "{}"
    private var holdOptionIsActive = false
    private var latestMediaSnapshot: NowPlayingSnapshot?

    var canEnableInteraction: Bool {
        currentProject?.kind == .web
    }

    var isInteractionEnabled: Bool {
        interactionMode == .always
            || interactionMode == .holdOption && holdOptionIsActive
    }

    var hasAppliedInteractiveMode: Bool {
        isInteractionEnabled
            && !windows.isEmpty
            && windows.allSatisfy(\.isInteractionEnabled)
    }

    private var manuallyPaused = false

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activeSpaceChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Public control

    /// Load a video and start playing it on every screen.
    func setWallpaper(url: URL) {
        currentProject = nil
        currentDisplayName = url.lastPathComponent
        content = .video(url)
        manuallyPaused = false
        interactionMode = .off
        holdOptionIsActive = false
        allowsNetworkAccess = false
        currentUserPropertiesJSON = "{}"
        rebuildWindows()
    }

    func setWallpaper(
        project: WallpaperProject,
        userPropertiesJSON: String? = nil,
        allowsNetworkAccess: Bool = false
    ) throws {
        guard project.isSupported, let entryURL = project.entryURL else {
            throw WallpaperProjectError.invalidManifest(
                "\(project.kind.displayName) wallpapers are not supported yet"
            )
        }

        currentProject = project
        currentDisplayName = project.title
        switch project.kind {
        case .video:
            content = .video(entryURL)
        case .web:
            content = .web(
                entryURL: entryURL,
                projectDirectoryURL: project.directoryURL
            )
        case .scene, .application, .unknown:
            throw WallpaperProjectError.invalidManifest(
                "\(project.kind.displayName) wallpapers are not supported yet"
            )
        }
        manuallyPaused = false
        interactionMode = .off
        holdOptionIsActive = false
        self.allowsNetworkAccess = allowsNetworkAccess && project.kind == .web
        currentUserPropertiesJSON =
            userPropertiesJSON ?? project.defaultUserPropertiesJSON
        rebuildWindows()
    }

    func pause() {
        manuallyPaused = true
        updatePlaybackState()
    }

    func resume() {
        manuallyPaused = false
        updatePlaybackState()
    }

    func reload() {
        rebuildWindows()
    }

    func setInteractionMode(_ mode: WallpaperInteractionMode) {
        interactionMode = canEnableInteraction ? mode : .off
        holdOptionIsActive = false
        applyInteractionState()
    }

    func setHoldOptionActive(_ active: Bool) {
        guard interactionMode == .holdOption else { return }
        holdOptionIsActive = active
        applyInteractionState()
    }

    func setInteractionEnabled(_ enabled: Bool) {
        setInteractionMode(enabled ? .always : .off)
    }

    func updateUserProperties(json: String) {
        currentUserPropertiesJSON = json
        windows.forEach { $0.applyUserProperties(json: json) }
    }

    func setNetworkAccessAllowed(_ allowed: Bool) {
        guard canEnableInteraction else { return }
        let newValue = allowed
        guard newValue != allowsNetworkAccess else { return }
        allowsNetworkAccess = newValue
        rebuildWindows()
    }

    func sendAudioSpectrum(_ samples: [Float]) {
        windows.forEach { $0.sendAudioSpectrum(samples) }
    }

    func sendMediaSnapshot(_ snapshot: NowPlayingSnapshot) {
        latestMediaSnapshot = snapshot
        windows.forEach { $0.sendMediaSnapshot(snapshot) }
    }

    func verifyWebHostCompatibility(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let window = windows.first else {
            completion(.failure(WallpaperEngineError.noWallpaperWindow))
            return
        }
        window.verifyWebHostCompatibility(completion: completion)
    }

    private func applyInteractionState() {
        windows.forEach {
            $0.setInteractionEnabled(isInteractionEnabled)
        }
    }

    // MARK: - Window / player lifecycle

    private func rebuildWindows() {
        teardown()
        guard let content else { return }

        var hasAssignedReadinessCallback = false
        for screen in NSScreen.screens {
            let window = WallpaperWindow(screen: screen)
            window.setVideoGravity(options.videoGravity)

            switch content {
            case .video(let url):
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                let player = AVQueuePlayer()
                player.isMuted = true
                player.actionAtItemEnd = .none
                let looper = AVPlayerLooper(player: player, templateItem: item)
                window.play(player: player)
                players.append(player)
                loopers.append(looper)
                if !hasAssignedReadinessCallback {
                    hasAssignedReadinessCallback = true
                    let readinessCallback = onContentReady
                    Task { @MainActor in
                        do {
                            let isPlayable = try await asset.load(.isPlayable)
                            if isPlayable {
                                readinessCallback?(.success(()))
                            } else {
                                readinessCallback?(.failure(
                                    WallpaperEngineError.videoNotPlayable(
                                        "AVFoundation rejected the video"
                                    )
                                ))
                            }
                        } catch {
                            readinessCallback?(.failure(
                                WallpaperEngineError.videoNotPlayable(
                                    error.localizedDescription
                                )
                            ))
                        }
                    }
                }
            case .web(let entryURL, let projectDirectoryURL):
                let readinessCallback: ((Result<Void, Error>) -> Void)?
                if hasAssignedReadinessCallback {
                    readinessCallback = nil
                } else {
                    hasAssignedReadinessCallback = true
                    readinessCallback = { [weak self] result in
                        self?.onContentReady?(result)
                    }
                }
                window.loadWebWallpaper(
                    entryURL: entryURL,
                    projectDirectoryURL: projectDirectoryURL,
                    userPropertiesJSON: currentUserPropertiesJSON,
                    allowsNetworkAccess: allowsNetworkAccess,
                    onLoad: readinessCallback
                )
            }

            window.setInteractionEnabled(isInteractionEnabled)
            if let latestMediaSnapshot {
                window.sendMediaSnapshot(latestMediaSnapshot)
            }
            windows.append(window)
        }

        applyPolicy()
    }

    private func teardown() {
        players.forEach { $0.pause() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        players.removeAll()
        loopers.removeAll()
    }

    // MARK: - Resource policy

    /// Decide whether playback should currently be paused based on options.
    private func shouldStayPaused() -> Bool {
        if options.pauseOnBattery && isOnBattery() { return true }
        if options.pauseWhenFullscreen && isFullscreenAppFrontmost() { return true }
        return false
    }

    func applyPolicy() {
        updatePlaybackState()
    }

    private func updatePlaybackState() {
        let shouldPause = manuallyPaused || shouldStayPaused()
        if shouldPause {
            players.forEach { $0.pause() }
            windows.forEach { $0.setPaused(true) }
        } else {
            players.forEach { $0.play() }
            windows.forEach { $0.setPaused(false) }
        }
    }

    private func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef] else { return false }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    /// Heuristic: is the frontmost app occupying an entire screen (fullscreen)?
    private func isFullscreenAppFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        // If any screen has no visible menu bar gap, a fullscreen window likely covers it.
        // A lightweight proxy: compare visibleFrame to full frame on the main screen.
        if let main = NSScreen.main {
            let coversMenuBar = abs(main.visibleFrame.height - main.frame.height) < 1.0
            return coversMenuBar
        }
        return false
    }

    // MARK: - Notifications

    @objc private func screensChanged() {
        // Displays added/removed/rearranged — rebuild to cover the new layout.
        rebuildWindows()
    }

    @objc private func activeSpaceChanged() {
        applyPolicy()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}

private enum WallpaperEngineError: LocalizedError {
    case videoNotPlayable(String)
    case noWallpaperWindow

    var errorDescription: String? {
        switch self {
        case .videoNotPlayable(let reason):
            return "The selected video is not playable: \(reason)"
        case .noWallpaperWindow:
            return "No wallpaper window is available."
        }
    }
}
