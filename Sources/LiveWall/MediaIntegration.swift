import AppKit
import Foundation

struct NowPlayingSnapshot: Equatable {
    enum PlaybackState: Int {
        case playing = 1
        case paused = 2
        case stopped = 3
    }

    let enabled: Bool
    let title: String
    let artist: String
    let albumTitle: String
    let state: PlaybackState
    let position: Double
    let duration: Double

    static let unavailable = NowPlayingSnapshot(
        enabled: false,
        title: "",
        artist: "",
        albumTitle: "",
        state: .stopped,
        position: 0,
        duration: 0
    )

    var javaScriptPayload: [String: Any] {
        [
            "status": ["enabled": enabled],
            "properties": [
                "title": title,
                "artist": artist,
                "albumTitle": albumTitle
            ],
            "playback": ["state": state.rawValue],
            "timeline": [
                "position": max(0, position),
                "duration": max(0, duration)
            ]
        ]
    }
}

/// Best-effort now-playing integration using the public AppleScript dictionaries
/// exposed by Music and Spotify. It is opt-in because macOS may request
/// Automation permission the first time each player is queried.
final class NowPlayingMonitor {

    var onUpdate: ((NowPlayingSnapshot) -> Void)?

    private let queue = DispatchQueue(
        label: "LiveWall.NowPlaying",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var lastSnapshot: NowPlayingSnapshot?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastSnapshot = nil
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(.unavailable)
        }
    }

    private func poll() {
        let spotify = snapshot(
            bundleIdentifier: "com.spotify.client",
            script: Self.spotifyScript
        )
        let music = snapshot(
            bundleIdentifier: "com.apple.Music",
            script: Self.musicScript
        )
        let selected = [spotify, music]
            .compactMap { $0 }
            .sorted {
                if $0.state != $1.state {
                    return $0.state == .playing
                }
                return !$0.title.isEmpty && $1.title.isEmpty
            }
            .first ?? NowPlayingSnapshot(
                enabled: true,
                title: "",
                artist: "",
                albumTitle: "",
                state: .stopped,
                position: 0,
                duration: 0
            )

        guard selected != lastSnapshot else { return }
        lastSnapshot = selected
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(selected)
        }
    }

    private func snapshot(
        bundleIdentifier: String,
        script: String
    ) -> NowPlayingSnapshot? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty else {
            return nil
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                return nil
            }
            let rawState = (object["state"] as? String)?.lowercased() ?? ""
            let state: NowPlayingSnapshot.PlaybackState
            if rawState.contains("playing") {
                state = .playing
            } else if rawState.contains("paused") {
                state = .paused
            } else {
                state = .stopped
            }
            return NowPlayingSnapshot(
                enabled: true,
                title: object["title"] as? String ?? "",
                artist: object["artist"] as? String ?? "",
                albumTitle: object["albumTitle"] as? String ?? "",
                state: state,
                position: (object["position"] as? NSNumber)?.doubleValue ?? 0,
                duration: (object["duration"] as? NSNumber)?.doubleValue ?? 0
            )
        } catch {
            return nil
        }
    }

    private static let spotifyScript = """
    const app = Application("Spotify");
    const track = app.currentTrack();
    JSON.stringify({
      title: String(track.name() || ""),
      artist: String(track.artist() || ""),
      albumTitle: String(track.album() || ""),
      state: String(app.playerState() || "stopped"),
      position: Number(app.playerPosition() || 0),
      duration: Number(track.duration() || 0) / 1000
    });
    """

    private static let musicScript = """
    const app = Application("Music");
    const track = app.currentTrack();
    JSON.stringify({
      title: String(track.name() || ""),
      artist: String(track.artist() || ""),
      albumTitle: String(track.album() || ""),
      state: String(app.playerState() || "stopped"),
      position: Number(app.playerPosition() || 0),
      duration: Number(track.duration() || 0)
    });
    """
}
