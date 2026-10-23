import AppKit
import AVFoundation
import WebKit

/// A borderless wallpaper window. It normally sits below Finder's desktop icons
/// and ignores input. Interactive web wallpapers can temporarily move just
/// above the icon layer and receive mouse and keyboard events.
final class WallpaperWindow: NSWindow {

    private static let passiveLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
    )
    private static let interactiveLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
    )

    private var playerView: PlayerLayerView?
    private var webView: WebWallpaperView?
    private var sceneView: SceneWallpaperView?
    private var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    private(set) var isInteractionEnabled = false

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Sit at the desktop-icon level minus 1 so we're behind the icons
        // but above the plain desktop background.
        self.level = Self.passiveLevel

        // Input is explicitly enabled only for supported web wallpapers.
        self.ignoresMouseEvents = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false

        // Follow the desktop across all Spaces and stay put in Mission Control /
        // fullscreen transitions.
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenNone
        ]

        self.setFrame(screen.frame, display: true)
        self.orderFrontRegardless()
    }

    /// Attach a player and begin playback filling the window.
    func play(player: AVQueuePlayer) {
        let playerView = PlayerLayerView(frame: contentLayoutRect)
        playerView.playerLayer.videoGravity = videoGravity
        playerView.attach(player: player)
        installContentView(playerView)
        self.playerView = playerView
    }

    /// Load a Wallpaper Engine web project without exposing native APIs or
    /// persistent browser storage. Remote HTTP(S) resources are blocked.
    func loadWebWallpaper(
        entryURL: URL,
        projectDirectoryURL: URL,
        userPropertiesJSON: String,
        allowsNetworkAccess: Bool,
        onLoad: ((Result<Void, Error>) -> Void)? = nil
    ) {
        let webView = WebWallpaperView(
            frame: contentLayoutRect,
            entryURL: entryURL,
            projectDirectoryURL: projectDirectoryURL,
            userPropertiesJSON: userPropertiesJSON,
            allowsNetworkAccess: allowsNetworkAccess,
            onLoad: onLoad
        )
        installContentView(webView)
        self.webView = webView
    }

    func loadSceneWallpaper(
        scene: SceneWallpaper,
        onLoad: ((Result<Void, Error>) -> Void)? = nil
    ) {
        do {
            let sceneView = try SceneWallpaperView(
                frame: contentLayoutRect,
                scene: scene
            )
            installContentView(sceneView)
            self.sceneView = sceneView
            DispatchQueue.main.async {
                onLoad?(.success(()))
            }
        } catch {
            onLoad?(.failure(error))
        }
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        videoGravity = gravity
        playerView?.playerLayer.videoGravity = gravity
    }

    func setPaused(_ paused: Bool) {
        webView?.setPaused(paused)
        sceneView?.setPaused(paused)
    }

    func captureSceneSnapshot(
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let sceneView else {
            completion(.failure(WallpaperWindowError.noSceneWallpaper))
            return
        }
        sceneView.captureNextFrame(to: url, completion: completion)
    }

    func applyUserProperties(json: String) {
        webView?.applyUserProperties(json: json)
    }

    func sendAudioSpectrum(_ samples: [Float]) {
        webView?.sendAudioSpectrum(samples)
    }

    func sendMediaSnapshot(_ snapshot: NowPlayingSnapshot) {
        webView?.sendMediaSnapshot(snapshot)
    }

    func verifyWebHostCompatibility(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let webView else {
            completion(.failure(WebWallpaperError.compatibilityProbeFailed))
            return
        }
        webView.verifyHostCompatibility(completion: completion)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        let shouldEnable = enabled && webView != nil
        isInteractionEnabled = shouldEnable
        ignoresMouseEvents = !shouldEnable
        acceptsMouseMovedEvents = shouldEnable
        level = shouldEnable ? Self.interactiveLevel : Self.passiveLevel

        if shouldEnable {
            orderFrontRegardless()
            makeKey()
            if let webView {
                makeFirstResponder(webView)
            }
        } else {
            if isKeyWindow {
                resignKey()
            }
            orderFrontRegardless()
        }
    }

    /// Resize to match a (possibly changed) screen frame.
    func updateFrame(to frame: NSRect) {
        self.setFrame(frame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
        playerView?.playerLayer.frame = playerView?.bounds ?? .zero
    }

    override var canBecomeKey: Bool { isInteractionEnabled }
    override var canBecomeMain: Bool { isInteractionEnabled }

    private func installContentView(_ view: NSView) {
        playerView = nil
        webView = nil
        sceneView = nil
        view.autoresizingMask = [.width, .height]
        view.frame = NSRect(origin: .zero, size: frame.size)
        contentView = view
    }
}

/// A layer-backed NSView whose backing layer is an AVPlayerLayer.
final class PlayerLayerView: NSView {

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func attach(player: AVQueuePlayer) {
        playerLayer.player = player
        playerLayer.frame = bounds
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// A deliberately small compatibility host for Wallpaper Engine web projects.
/// It provides the common global callbacks, blocks remote resources and does
/// not expose a native message bridge.
final class WebWallpaperView: WKWebView, WKNavigationDelegate {

    private let entryURL: URL
    private let projectDirectoryURL: URL
    private var userPropertiesJSON: String
    private let allowsNetworkAccess: Bool
    private var onLoad: ((Result<Void, Error>) -> Void)?
    private var isWallpaperPaused = false
    private var hasFinishedLoading = false
    private var pendingAudioSpectrum: [Float]?
    private var pendingMediaSnapshot: NowPlayingSnapshot?

    private static let compatibilityScript = """
    (() => {
      if (window.__livewallInstalled) return;
      window.__livewallInstalled = true;
      window.wallpaperPropertyListener = window.wallpaperPropertyListener || {};

      let audioListener = null;
      window.wallpaperRegisterAudioListener = function(listener) {
        audioListener = typeof listener === "function" ? listener : null;
      };
      window.__livewallPushAudio = function(samples) {
        if (audioListener) audioListener(samples);
      };

      const mediaListeners = {
        status: null,
        properties: null,
        thumbnail: null,
        playback: null,
        timeline: null
      };
      const mediaRegistrationNames = {
        Status: "status",
        Properties: "properties",
        Thumbnail: "thumbnail",
        Playback: "playback",
        Timeline: "timeline"
      };
      for (const [suffix, key] of Object.entries(mediaRegistrationNames)) {
        window["wallpaperRegisterMedia" + suffix + "Listener"] = function(listener) {
          mediaListeners[key] = typeof listener === "function" ? listener : null;
        };
      }
      window.wallpaperMediaIntegration = window.wallpaperMediaIntegration || {
        PLAYBACK_PLAYING: 1,
        PLAYBACK_PAUSED: 2,
        PLAYBACK_STOPPED: 3,
        playback: { PLAYING: 1, PAUSED: 2, STOPPED: 3 }
      };
      window.__livewallPushMedia = function(payload) {
        for (const key of Object.keys(mediaListeners)) {
          if (mediaListeners[key] && payload[key] !== undefined) {
            mediaListeners[key](payload[key]);
          }
        }
      };

      const nativeRAF = window.requestAnimationFrame.bind(window);
      const nativeCancelRAF = window.cancelAnimationFrame.bind(window);
      const queuedFrames = new Map();
      let nextFrameID = 1000000;
      let paused = false;

      window.requestAnimationFrame = function(callback) {
        if (!paused) return nativeRAF(callback);
        const id = nextFrameID++;
        queuedFrames.set(id, callback);
        return id;
      };
      window.cancelAnimationFrame = function(id) {
        if (queuedFrames.delete(id)) return;
        nativeCancelRAF(id);
      };
      window.__livewallSetPaused = function(value) {
        paused = !!value;
        let style = document.getElementById("__livewall_pause_style");
        if (paused) {
          if (!style) {
            style = document.createElement("style");
            style.id = "__livewall_pause_style";
            style.textContent = "*,*::before,*::after{animation-play-state:paused!important}";
            (document.head || document.documentElement).appendChild(style);
          }
          document.querySelectorAll("video,audio").forEach((media) => {
            media.dataset.livewallWasPlaying = media.paused ? "0" : "1";
            media.pause();
          });
        } else {
          if (style) style.remove();
          const pending = Array.from(queuedFrames.values());
          queuedFrames.clear();
          pending.forEach((callback) => nativeRAF(callback));
          document.querySelectorAll("video,audio").forEach((media) => {
            if (media.dataset.livewallWasPlaying === "1") media.play().catch(() => {});
            delete media.dataset.livewallWasPlaying;
          });
        }
      };
    })();
    """

    init(
        frame: NSRect,
        entryURL: URL,
        projectDirectoryURL: URL,
        userPropertiesJSON: String,
        allowsNetworkAccess: Bool,
        onLoad: ((Result<Void, Error>) -> Void)?
    ) {
        self.entryURL = entryURL
        self.projectDirectoryURL = projectDirectoryURL.resolvingSymlinksInPath()
        self.userPropertiesJSON = userPropertiesJSON
        self.allowsNetworkAccess = allowsNetworkAccess
        self.onLoad = onLoad

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.compatibilityScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            isInspectable = false
        }

        installNetworkPolicyAndLoad()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setPaused(_ paused: Bool) {
        isWallpaperPaused = paused
        guard hasFinishedLoading else { return }
        applyPauseState(completion: nil)
    }

    func applyUserProperties(json: String) {
        userPropertiesJSON = json
        guard hasFinishedLoading else { return }
        callAsyncJavaScript(
            """
            const listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === "function") {
              listener.applyUserProperties(JSON.parse(propertiesJSON));
            }
            """,
            arguments: ["propertiesJSON": json],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func sendAudioSpectrum(_ samples: [Float]) {
        pendingAudioSpectrum = samples
        guard hasFinishedLoading else { return }
        callAsyncJavaScript(
            """
            if (typeof window.__livewallPushAudio === "function") {
              window.__livewallPushAudio(samples);
            }
            """,
            arguments: ["samples": samples.map(Double.init)],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func sendMediaSnapshot(_ snapshot: NowPlayingSnapshot) {
        pendingMediaSnapshot = snapshot
        guard hasFinishedLoading else { return }
        callAsyncJavaScript(
            """
            if (typeof window.__livewallPushMedia === "function") {
              window.__livewallPushMedia(payload);
            }
            """,
            arguments: ["payload": snapshot.javaScriptPayload],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    func verifyHostCompatibility(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard hasFinishedLoading else {
            completion(.failure(WebWallpaperError.compatibilityProbeFailed))
            return
        }
        callAsyncJavaScript(
            """
            let audioReceived = false;
            let mediaReceived = false;
            window.wallpaperRegisterAudioListener(function(samples) {
              audioReceived = Array.isArray(samples) && samples.length === 128;
            });
            window.wallpaperRegisterMediaStatusListener(function(status) {
              mediaReceived = status && status.enabled === true;
            });
            window.__livewallPushAudio(new Array(128).fill(0.25));
            window.__livewallPushMedia({ status: { enabled: true } });
            const listener = window.wallpaperPropertyListener;
            return audioReceived && mediaReceived &&
              !!listener && typeof listener.applyUserProperties === "function";
            """,
            arguments: [:],
            in: nil,
            in: .page,
            completionHandler: { result in
                switch result {
                case .success(let value):
                    if value as? Bool == true {
                        completion(.success(()))
                    } else {
                        completion(.failure(
                            WebWallpaperError.compatibilityProbeFailed
                        ))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
    }

    private func installNetworkPolicyAndLoad() {
        if allowsNetworkAccess {
            loadProject()
            return
        }

        let rules = """
        [{
          "trigger": {"url-filter": "^https?://.*"},
          "action": {"type": "block"}
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "LiveWall.BlockRemoteResources.v1",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, let ruleList else {
                    self.finishLoading(.failure(
                        WebWallpaperError.remoteResourceBlockerInitializationFailed
                    ))
                    self.loadHTMLString(
                        "<html><body style='background:#111;color:#eee;font-family:-apple-system;padding:24px'>LiveWall could not initialize its web-wallpaper safety rules.</body></html>",
                        baseURL: nil
                    )
                    return
                }
                self.configuration.userContentController.add(ruleList)
                self.loadProject()
            }
        }
    }

    private func loadProject() {
        loadFileURL(
            entryURL,
            allowingReadAccessTo: projectDirectoryURL
        )
    }

    private func applyPauseState(completion: ((Error?) -> Void)?) {
        callAsyncJavaScript(
            """
            if (typeof window.__livewallSetPaused === "function") {
              window.__livewallSetPaused(paused);
            }
            const listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.setPaused === "function") {
              listener.setPaused(paused);
            }
            """,
            arguments: ["paused": isWallpaperPaused],
            in: nil,
            in: .page,
            completionHandler: { result in
                switch result {
                case .success:
                    completion?(nil)
                case .failure(let error):
                    completion?(error)
                }
            }
        )
        setAllMediaPlaybackSuspended(isWallpaperPaused)
    }

    private func applyInitialHostState(completion: @escaping (Error?) -> Void) {
        callAsyncJavaScript(
            """
            const listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyGeneralProperties === "function") {
              listener.applyGeneralProperties({ fps: 30 });
            }
            if (listener && typeof listener.applyUserProperties === "function") {
              listener.applyUserProperties(JSON.parse(propertiesJSON));
            }
            if (listener && typeof listener.setPaused === "function") {
              listener.setPaused(paused);
            }
            if (typeof window.__livewallSetPaused === "function") {
              window.__livewallSetPaused(paused);
            }
            if (window.rhineWallpaperPropertiesReady &&
                typeof window.rhineWallpaperPropertiesReady.then === "function") {
              await window.rhineWallpaperPropertiesReady;
            }
            return true;
            """,
            arguments: [
                "propertiesJSON": userPropertiesJSON,
                "paused": isWallpaperPaused
            ],
            in: nil,
            in: .page,
            completionHandler: { result in
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            }
        )
        setAllMediaPlaybackSuspended(isWallpaperPaused)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedLoading = true
        applyInitialHostState { [weak self] error in
            guard let self else { return }
            if let error {
                self.finishLoading(.failure(error))
            } else {
                if let samples = self.pendingAudioSpectrum {
                    self.sendAudioSpectrum(samples)
                }
                if let snapshot = self.pendingMediaSnapshot {
                    self.sendMediaSnapshot(snapshot)
                }
                self.finishLoading(.success(()))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if allowsNetworkAccess,
           url.scheme == "http" || url.scheme == "https" {
            decisionHandler(
                navigationAction.targetFrame?.isMainFrame == true
                    ? .cancel
                    : .allow
            )
            return
        }
        guard url.isFileURL else {
            decisionHandler(.cancel)
            return
        }

        let candidate = url.resolvingSymlinksInPath()
        let rootPath = projectDirectoryURL.path.hasSuffix("/")
            ? projectDirectoryURL.path
            : projectDirectoryURL.path + "/"
        decisionHandler(
            candidate.path == projectDirectoryURL.path || candidate.path.hasPrefix(rootPath)
                ? .allow
                : .cancel
        )
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        guard let onLoad else { return }
        self.onLoad = nil
        onLoad(result)
    }
}

private enum WebWallpaperError: LocalizedError {
    case remoteResourceBlockerInitializationFailed
    case compatibilityProbeFailed

    var errorDescription: String? {
        switch self {
        case .remoteResourceBlockerInitializationFailed:
            return "WebKit could not initialize the remote-resource blocking rules."
        case .compatibilityProbeFailed:
            return "The web wallpaper host compatibility probe failed."
        }
    }
}

private enum WallpaperWindowError: LocalizedError {
    case noSceneWallpaper

    var errorDescription: String? {
        switch self {
        case .noSceneWallpaper:
            return "No scene wallpaper is available."
        }
    }
}
