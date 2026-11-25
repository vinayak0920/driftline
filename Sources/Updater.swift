import Foundation
import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer Driftline, asks the user, then downloads,
/// verifies (Ed25519 signature), installs and relaunches.
///
/// Configuration lives in Info.plist:
///   DriftlineUpdateRepo       "owner/repo"
///   DriftlineUpdatePublicKey  base64 Ed25519 public key (from scripts/setup-updates.sh)
/// Each release needs Driftline.zip and Driftline.zip.sig (the GitHub workflow adds both).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
        let signatureURL: URL?
        let pageURL: URL
    }

    static let autoCheckKey = "updatesAutoCheck"
    private static let skippedKey = "updatesSkippedVersion"

    @Published private(set) var state: State = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private let repo = Bundle.main.object(forInfoDictionaryKey: "DriftlineUpdateRepo") as? String
    private let publicKey: Curve25519.Signing.PublicKey? = {
        guard let b64 = Bundle.main.object(forInfoDictionaryKey: "DriftlineUpdatePublicKey") as? String,
              let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()
    private var timer: Timer?

    var availableRelease: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    // MARK: Scheduling

    func start() {
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
        guard repo != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            Task { @MainActor in self?.autoCheck() }
        }
        let t = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoCheck() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func autoCheck() {
        guard UserDefaults.standard.bool(forKey: Self.autoCheckKey) else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard let repo, let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking

        do {
            var request = URLRequest(url: api)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Driftline/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                throw UpdateError.badResponse
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ name: String) -> URL? {
                assets.first { ($0["name"] as? String) == name }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap(URL.init(string:))
            }
            guard Self.isNewer(version, than: currentVersion), let zip = asset("Driftline.zip") else {
                state = .upToDate
                if userInitiated { alertUpToDate() }
                return
            }
            let release = Release(version: version,
                                  notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  zipURL: zip,
                                  signatureURL: asset("Driftline.zip.sig"),
                                  pageURL: page)
            state = .available(release)

            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if userInitiated || skipped != version { prompt(release) }
        } catch {
            state = .failed("Couldn't check for updates. Check your internet connection.")
            if userInitiated { alert(title: "Couldn't check for updates", text: "Check your internet connection and try again.") }
        }
    }

    /// "1.10.0" > "1.9.2", "1.1" == "1.1.0"
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Prompt

    private func prompt(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Driftline \(release.version) is available"
        var info = "You have version \(currentVersion)."
        if !release.notes.isEmpty {
            let notes = release.notes.count > 600 ? String(release.notes.prefix(600)) + "…" : release.notes
            info += "\n\nWhat's new:\n" + notes
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        if let icon = NSApp.applicationIconImage { alert.icon = icon }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }

    // MARK: Installing

    func installAvailable() {
        if let release = availableRelease { install(release) }
    }

    func install(_ release: Release) {
        // Without a signature (or a key to check it) we never install automatically:
        // send the user to the release page instead.
        guard publicKey != nil, release.signatureURL != nil else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            alert(title: "Move Driftline to Applications first",
                  text: "Driftline can only update itself from your Applications folder. Drag it there, open it again, and choose Check for Updates.")
            return
        }
        Task { await downloadAndInstall(release, appURL: appURL) }
    }

    private func downloadAndInstall(_ release: Release, appURL: URL) async {
        do {
            state = .downloading(0)
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("driftline-update-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            let zipData = try await download(release.zipURL)
            guard let sigURL = release.signatureURL, let key = publicKey else { throw UpdateError.unsigned }
            let signature = try await URLSession.shared.data(from: sigURL).0

            // The important part: only install a zip signed by our own release workflow.
            guard key.isValidSignature(signature, for: zipData) else { throw UpdateError.badSignature }

            state = .installing
            let zipFile = work.appendingPathComponent("Driftline.zip")
            try zipData.write(to: zipFile)
            try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])

            let newApp = work.appendingPathComponent("Driftline.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError.wrongApp
            }

            // A tiny script swaps the apps after we quit, then relaunches Driftline.
            // If the swap fails it puts the old app back and shows the new one in Finder.
            let script = work.appendingPathComponent("install.sh")
            let target = appURL.path
            try """
            #!/bin/sh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            if mv "\(target)" "\(target).old" && mv "\(newApp.path)" "\(target)"; then
              rm -rf "\(target).old"
              xattr -cr "\(target)"
              open "\(target)"
            else
              [ -d "\(target).old" ] && [ ! -d "\(target)" ] && mv "\(target).old" "\(target)"
              open -R "\(newApp.path)"
            fi
            """.write(to: script, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            alert(title: "Update failed", text: message + "\n\nYou can download it from GitHub instead.")
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func download(_ url: URL) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        let expected = max(response.expectedContentLength, 1)
        var data = Data()
        data.reserveCapacity(Int(expected))
        var lastReport = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count - lastReport > 64 * 1024 {
                lastReport = data.count
                state = .downloading(min(Double(data.count) / Double(expected), 1))
            }
        }
        return data
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.unzip }
    }

    // MARK: Alerts

    private func alertUpToDate() {
        alert(title: "You're up to date", text: "Driftline \(currentVersion) is the newest version.")
    }

    private func alert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

enum UpdateError: LocalizedError {
    case badResponse, unsigned, badSignature, unzip, wrongApp

    var errorDescription: String? {
        switch self {
        case .badResponse: return "GitHub didn't return the update correctly."
        case .unsigned: return "This update isn't signed, so Driftline won't install it automatically."
        case .badSignature: return "The update's signature didn't match. Driftline didn't install it, for your safety."
        case .unzip: return "Couldn't unpack the update."
        case .wrongApp: return "The downloaded file wasn't Driftline."
        }
    }
}
