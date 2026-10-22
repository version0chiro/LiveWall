import Foundation

struct SteamWorkshopItem: Equatable {
    let id: String
    let sourceURL: URL
}

enum SteamWorkshopLinkError: LocalizedError {
    case empty
    case catalogURL
    case unsupportedHost
    case missingItemID
    case invalidItemID

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste an individual Steam Workshop wallpaper link."
        case .catalogURL:
            return """
            This is the Workshop catalogue. Open one wallpaper, then copy its \
            URL containing sharedfiles/filedetails/?id=…
            """
        case .unsupportedHost:
            return "Only steamcommunity.com Workshop links are accepted."
        case .missingItemID:
            return "The Workshop link does not contain an item ID."
        case .invalidItemID:
            return "The Workshop item ID must be a positive number."
        }
    }
}

struct SteamWorkshopLinkParser {
    static func parse(_ rawValue: String) throws -> SteamWorkshopItem {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SteamWorkshopLinkError.empty
        }

        if isValidItemID(value) {
            return SteamWorkshopItem(
                id: value,
                sourceURL: canonicalURL(itemID: value)
            )
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else {
            throw SteamWorkshopLinkError.missingItemID
        }

        if scheme == "steam" {
            let pathComponents = components.path
                .split(separator: "/")
                .map(String.init)
            guard components.host?.lowercased() == "url",
                  pathComponents.count == 2,
                  pathComponents[0].lowercased() == "communityfilepage" else {
                throw SteamWorkshopLinkError.missingItemID
            }
            let itemID = pathComponents[1]
            guard isValidItemID(itemID) else {
                throw SteamWorkshopLinkError.invalidItemID
            }
            return SteamWorkshopItem(
                id: itemID,
                sourceURL: canonicalURL(itemID: itemID)
            )
        }

        guard scheme == "https" || scheme == "http" else {
            throw SteamWorkshopLinkError.unsupportedHost
        }
        let host = components.host?.lowercased()
        guard host == "steamcommunity.com" || host == "www.steamcommunity.com" else {
            throw SteamWorkshopLinkError.unsupportedHost
        }
        if components.path.hasPrefix("/app/431960/workshop") {
            throw SteamWorkshopLinkError.catalogURL
        }
        guard components.path.lowercased().contains("filedetails") else {
            throw SteamWorkshopLinkError.missingItemID
        }
        guard let itemID = components.queryItems?
            .first(where: { $0.name.lowercased() == "id" })?
            .value else {
            throw SteamWorkshopLinkError.missingItemID
        }
        guard isValidItemID(itemID) else {
            throw SteamWorkshopLinkError.invalidItemID
        }

        return SteamWorkshopItem(
            id: itemID,
            sourceURL: canonicalURL(itemID: itemID)
        )
    }

    private static func isValidItemID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 20
            && value.allSatisfy(\.isNumber)
            && UInt64(value).map { $0 > 0 } == true
    }

    private static func canonicalURL(itemID: String) -> URL {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(itemID)")!
    }
}

struct SteamWorkshopDownloadJob {
    let itemID: String
    let scriptURL: URL
    let successMarkerURL: URL
    let failureMarkerURL: URL
    let manifestURL: URL
    let createdAt: Date
}

enum SteamWorkshopManagerError: LocalizedError {
    case steamCMDNotInstalled(String)
    case invalidAccountName
    case couldNotPrepareDownload(String)

    var errorDescription: String? {
        switch self {
        case .steamCMDNotInstalled(let path):
            return "SteamCMD is not installed at \(path)."
        case .invalidAccountName:
            return """
            Enter your Steam account name using letters, numbers, underscores \
            or hyphens. Do not enter your display name, password or Steam Guard code.
            """
        case .couldNotPrepareDownload(let reason):
            return "Could not prepare the SteamCMD download: \(reason)"
        }
    }
}

struct SteamWorkshopManager {
    static let wallpaperEngineAppID = "431960"

    let rootURL: URL
    private let workshopRootOverride: URL?

    init(rootURL: URL? = nil, workshopRootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootURL = applicationSupport
                .appendingPathComponent("LiveWall", isDirectory: true)
                .standardizedFileURL
        }
        workshopRootOverride = workshopRootURL?.standardizedFileURL
    }

    var steamCMDDirectoryURL: URL {
        rootURL.appendingPathComponent("SteamCMD", isDirectory: true)
    }

    var steamCMDExecutableURL: URL {
        steamCMDDirectoryURL.appendingPathComponent("steamcmd.sh")
    }

    var workshopRootURL: URL {
        if let workshopRootOverride {
            return workshopRootOverride
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Steam/steamapps/workshop/content",
                isDirectory: true
            )
            .appendingPathComponent(Self.wallpaperEngineAppID, isDirectory: true)
            .standardizedFileURL
    }

    var isSteamCMDInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: steamCMDExecutableURL.path)
    }

    func manifestURL(itemID: String) -> URL {
        workshopRootURL
            .appendingPathComponent(itemID, isDirectory: true)
            .appendingPathComponent(WallpaperProjectLoader.manifestFilename)
    }

    func existingProject(itemID: String) -> WallpaperProject? {
        try? WallpaperProjectLoader.load(manifestURL: manifestURL(itemID: itemID))
    }

    func detectedSteamAccountName(loginUsersURL: URL? = nil) -> String? {
        let sourceURL = loginUsersURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Steam/config/loginusers.vdf"
                )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }

        let blockPattern = #""[0-9]+"\s*\{(.*?)\}"#
        guard let blockExpression = try? NSRegularExpression(
            pattern: blockPattern,
            options: [.dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var candidates: [(accountName: String, mostRecent: Bool, timestamp: UInt64)] = []
        for match in blockExpression.matches(in: source, range: sourceRange) {
            guard let blockRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            let block = String(source[blockRange])
            guard let accountName = vdfValue("AccountName", in: block),
                  Self.isValidAccountName(accountName) else {
                continue
            }
            candidates.append((
                accountName: accountName,
                mostRecent: vdfValue("MostRecent", in: block) == "1",
                timestamp: UInt64(vdfValue("Timestamp", in: block) ?? "") ?? 0
            ))
        }

        return candidates.sorted {
            if $0.mostRecent != $1.mostRecent {
                return $0.mostRecent && !$1.mostRecent
            }
            return $0.timestamp > $1.timestamp
        }.first?.accountName
    }

    func prepareDownload(itemID: String, accountName: String) throws -> SteamWorkshopDownloadJob {
        guard isSteamCMDInstalled else {
            throw SteamWorkshopManagerError.steamCMDNotInstalled(
                steamCMDExecutableURL.path
            )
        }
        guard Self.isValidAccountName(accountName) else {
            throw SteamWorkshopManagerError.invalidAccountName
        }
        guard itemID.allSatisfy(\.isNumber), !itemID.isEmpty else {
            throw SteamWorkshopLinkError.invalidItemID
        }

        let jobsURL = rootURL.appendingPathComponent("DownloadJobs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: jobsURL,
                withIntermediateDirectories: true
            )

            let successURL = jobsURL.appendingPathComponent("\(itemID).success")
            let failureURL = jobsURL.appendingPathComponent("\(itemID).failure")
            let scriptURL = jobsURL.appendingPathComponent("\(itemID).command")
            for staleURL in [successURL, failureURL, scriptURL] {
                try? FileManager.default.removeItem(at: staleURL)
            }

            let manifestURL = manifestURL(itemID: itemID)
            let script = commandScript(
                itemID: itemID,
                accountName: accountName,
                manifestURL: manifestURL,
                successURL: successURL,
                failureURL: failureURL
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )

            return SteamWorkshopDownloadJob(
                itemID: itemID,
                scriptURL: scriptURL,
                successMarkerURL: successURL,
                failureMarkerURL: failureURL,
                manifestURL: manifestURL,
                createdAt: Date()
            )
        } catch {
            throw SteamWorkshopManagerError.couldNotPrepareDownload(
                error.localizedDescription
            )
        }
    }

    func cleanup(job: SteamWorkshopDownloadJob) {
        for url in [job.scriptURL, job.successMarkerURL, job.failureMarkerURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func isValidAccountName(_ value: String) -> Bool {
        let accountName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountName.isEmpty, accountName.count <= 64 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        return accountName.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func vdfValue(_ key: String, in block: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #""\#(escapedKey)"\s*"([^"]*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: block,
                  range: NSRange(block.startIndex..<block.endIndex, in: block)
              ),
              let valueRange = Range(match.range(at: 1), in: block) else {
            return nil
        }
        return String(block[valueRange])
    }

    private func commandScript(
        itemID: String,
        accountName: String,
        manifestURL: URL,
        successURL: URL,
        failureURL: URL
    ) -> String {
        let steamCMD = shellQuote(steamCMDExecutableURL.path)
        let workingDirectory = shellQuote(steamCMDDirectoryURL.path)
        let account = shellQuote(
            accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let item = shellQuote(itemID)
        let manifest = shellQuote(manifestURL.path)
        let success = shellQuote(successURL.path)
        let failure = shellQuote(failureURL.path)

        return """
        #!/bin/zsh
        set -u

        rm -f \(success) \(failure)
        cd \(workingDirectory)

        echo "LiveWall - Wallpaper Engine Workshop download"
        echo "Item: \(itemID)"
        echo
        echo "SteamCMD may ask for your Steam password and Steam Guard code."
        echo "These are entered directly into Valve's SteamCMD, not LiveWall."
        echo

        \(steamCMD) \
          +@ShutdownOnFailedCommand 1 \
          +login \(account) \
          +workshop_download_item \(Self.wallpaperEngineAppID) \(item) validate \
          +quit
        exit_code=$?

        if [[ $exit_code -eq 0 && -f \(manifest) ]]; then
          touch \(success)
          echo
          echo "Download complete. LiveWall will import the wallpaper automatically."
        else
          print -r -- "$exit_code" > \(failure)
          echo
          echo "Download did not complete. Review the SteamCMD output above."
        fi

        echo
        read -k 1 "?Press any key to close this Terminal window..."
        echo
        exit $exit_code
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
