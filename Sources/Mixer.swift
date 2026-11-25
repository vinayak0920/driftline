import Foundation
import AppKit
import CoreAudio
import AudioToolbox

// Per-app volume, built on Apple's Core Audio process taps (macOS 14.2+).
//
// How it works: when you turn an app down, Driftline creates a private "tap" on that
// app's audio (which mutes the original), wraps it in a private aggregate device with
// your speakers, and plays the audio back with your volume applied. At 100% the tap
// is removed and the app plays exactly as before. macOS asks for "System Audio
// Recording" permission the first time; Driftline never records or stores audio.

/// One row in the Sound tab: an app (with all its helper processes) that makes sound.
struct AudioApp: Identifiable, Equatable {
    let id: String              // main app bundle id, or "pid:123"
    let name: String
    let icon: NSImage?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

// MARK: - Core Audio helpers

enum CoreAudioProps {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Int32>.size)
        var value: Int32 = 0
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultOutputUID() -> String? {
        guard let device = uint32(system, kAudioHardwarePropertyDefaultOutputDevice),
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}

enum MixerError: LocalizedError {
    case noOutput, tap(OSStatus), aggregate(OSStatus), ioProc(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutput: return "No audio output device was found."
        case .tap(let s): return "macOS refused to adjust this app's audio (error \(s))."
        case .aggregate(let s): return "Couldn't set up the audio route (error \(s))."
        case .ioProc(let s): return "Couldn't start the audio route (error \(s))."
        }
    }
}

// MARK: - One app's tap

@available(macOS 14.2, *)
final class AppAudioTap {
    let processObjects: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Read on the realtime audio thread, written from the main thread.
    private let gain: UnsafeMutablePointer<Float>
    /// Set by the audio thread once real (non-silent) audio arrives.
    private let heardSignal: UnsafeMutablePointer<Bool>
    let createdAt = Date()

    var hasHeardSignal: Bool { heardSignal.pointee }

    init(processObjects: [AudioObjectID], outputUID: String, gain initial: Float) throws {
        self.processObjects = processObjects
        gain = .allocate(capacity: 1)
        gain.initialize(to: initial)
        heardSignal = .allocate(capacity: 1)
        heardSignal.initialize(to: false)

        // Every stored property is set by now, so if build() throws, deinit still runs and
        // cleans up whatever was created. Don't clean up here too, or it would happen twice.
        try build(outputUID: outputUID)
    }

    deinit {
        teardown()
        gain.deallocate()
        heardSignal.deallocate()
    }

    func setGain(_ value: Float) {
        gain.pointee = max(0, min(value, 1))
    }

    private func build(outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped   // silence the original while we play our copy
        description.name = "Driftline per-app volume"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw MixerError.tap(status) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Driftline Mixer",
            kAudioAggregateDeviceUIDKey: "com.apavin.driftline.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { throw MixerError.aggregate(status) }
        aggregateID = device

        let gain = self.gain
        let heard = self.heardSignal
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, inInput, _, outOutput, _ in
            Self.render(input: inInput, output: outOutput, gain: gain.pointee, heard: heard)
        }
        guard status == noErr, let proc else { throw MixerError.ioProc(status) }
        procID = proc

        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw MixerError.ioProc(status) }
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Realtime audio thread: copy the tapped audio to the speakers with the gain applied.
    /// No allocation or locking here. Handles interleaved and non-interleaved buffers.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float,
                               heard: UnsafeMutablePointer<Bool>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var inChannels = 0
        for buffer in inList { inChannels += Int(buffer.mNumberChannels) }

        var outChannelIndex = 0
        for outBuffer in outList {
            guard let outData = outBuffer.mData else { continue }
            let outStride = max(Int(outBuffer.mNumberChannels), 1)
            let outFrames = Int(outBuffer.mDataByteSize) / MemoryLayout<Float>.size / outStride
            let dst = outData.assumingMemoryBound(to: Float.self)

            for channel in 0..<outStride {
                let global = outChannelIndex + channel
                // Mono input plays on both speakers; otherwise channel N → channel N.
                let source = inChannels == 1 ? (global < 2 ? 0 : -1) : (global < inChannels ? global : -1)

                var written = 0
                if source >= 0 {
                    var remaining = source
                    for inBuffer in inList {
                        let inStride = Int(inBuffer.mNumberChannels)
                        if remaining < inStride, let inData = inBuffer.mData {
                            let src = inData.assumingMemoryBound(to: Float.self)
                            let inFrames = Int(inBuffer.mDataByteSize) / MemoryLayout<Float>.size / max(inStride, 1)
                            let frames = min(inFrames, outFrames)
                            for f in 0..<frames {
                                let sample = src[f * inStride + remaining]
                                if sample != 0 && !heard.pointee { heard.pointee = true }
                                dst[f * outStride + channel] = sample * gain
                            }
                            written = frames
                            break
                        }
                        remaining -= inStride
                    }
                }
                if written < outFrames {
                    for f in written..<outFrames { dst[f * outStride + channel] = 0 }
                }
            }
            outChannelIndex += outStride
        }
    }
}

// MARK: - Mixer

@MainActor
final class AppVolumeMixer: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published var notice: String?

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private static let volumesKey = "mixerVolumes"
    private static let mutedKey = "mixerMuted"
    private static let permissionHelp =
        "Allow Driftline in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then try again."

    private var taps: [String: AnyObject] = [:]   // AppAudioTap, stored untyped for macOS 13 builds
    private var timer: Timer?
    private var visible = false
    private var outputUID: String?

    init() {
        let d = UserDefaults.standard
        volumes = d.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        muted = Set(d.stringArray(forKey: Self.mutedKey) ?? [])
    }

    func start() {
        guard Self.isSupported else { return }
        outputUID = CoreAudioProps.defaultOutputUID()
        listenForOutputChanges()
        refresh()
        scheduleTimer()
    }

    func setVisible(_ isVisible: Bool) {
        visible = isVisible
        if isVisible { refresh() }
        scheduleTimer()
    }

    // MARK: Levels

    func volume(for app: AudioApp) -> Double { volumes[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.id) }

    func setVolume(_ value: Double, for app: AudioApp) {
        volumes[app.id] = value >= 0.995 ? nil : value
        if value > 0.005 { muted.remove(app.id) }
        persist()
        apply(app)
    }

    func toggleMute(_ app: AudioApp) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        persist()
        apply(app)
    }

    func resetAll() {
        volumes = [:]
        muted = []
        persist()
        taps.removeAll() // deinit tears each tap down and restores normal audio
        notice = nil
        permissionNoticeShown = false
    }

    private func effectiveGain(_ id: String) -> Float {
        muted.contains(id) ? 0 : Float(volumes[id] ?? 1)
    }

    private func persist() {
        UserDefaults.standard.set(volumes, forKey: Self.volumesKey)
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
    }

    // MARK: Taps

    private func apply(_ app: AudioApp) {
        guard #available(macOS 14.2, *) else { return }
        let gain = effectiveGain(app.id)

        // Back to 100%: remove the tap so the app plays untouched.
        if gain >= 0.995 {
            taps[app.id] = nil
            return
        }
        if let existing = taps[app.id] as? AppAudioTap,
           Set(existing.processObjects) == Set(app.processObjects) {
            existing.setGain(gain)
            return
        }
        guard let output = outputUID ?? CoreAudioProps.defaultOutputUID() else {
            notice = MixerError.noOutput.localizedDescription
            return
        }
        taps[app.id] = nil
        do {
            taps[app.id] = try AppAudioTap(processObjects: app.processObjects, outputUID: output, gain: gain)
        } catch {
            notice = error.localizedDescription + " " + Self.permissionHelp
        }
    }

    /// If none of our taps has heard any sound for a while even though those apps are
    /// playing, macOS most likely denied the audio permission. Explain how to fix it.
    /// (We don't remove taps automatically: some apps "play" silence, and that would loop.)
    private var permissionNoticeShown = false

    private func checkForSilentTaps() {
        guard #available(macOS 14.2, *), !permissionNoticeShown else { return }
        let active = apps.compactMap { app -> AppAudioTap? in
            guard app.isPlaying, effectiveGain(app.id) > 0 else { return nil }
            return taps[app.id] as? AppAudioTap
        }
        guard !active.isEmpty,
              active.allSatisfy({ !$0.hasHeardSignal && Date().timeIntervalSince($0.createdAt) > 8 })
        else { return }
        permissionNoticeShown = true
        notice = "Can't hear the apps you adjusted? " + Self.permissionHelp
            + " Or tap Reset all to go back to normal."
    }

    // MARK: Discovering apps

    private func scheduleTimer() {
        timer?.invalidate()
        guard Self.isSupported else { return }
        // Fast while you're looking at the Sound tab; slow in the background so saved
        // levels still apply when an app starts playing later.
        let interval: TimeInterval = visible ? 1.5 : 5
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard #available(macOS 14.2, *) else { return }
        let found = discoverApps()
        if found != apps { apps = found }

        // Re-apply saved levels (new helper processes, apps that just started playing).
        for app in found where effectiveGain(app.id) < 0.995 {
            if let tap = taps[app.id] as? AppAudioTap,
               Set(tap.processObjects) == Set(app.processObjects) { continue }
            apply(app)
        }
        // Drop taps for apps that have quit.
        let liveIDs = Set(found.map(\.id))
        for id in taps.keys where !liveIDs.contains(id) { taps[id] = nil }

        checkForSilentTaps()
    }

    @available(macOS 14.2, *)
    private func discoverApps() -> [AudioApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var groups: [String: AudioApp] = [:]

        for object in CoreAudioProps.objectIDs(CoreAudioProps.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CoreAudioProps.int32(object, kAudioProcessPropertyPID), pid > 0, pid != me else { continue }
            let bundleID = CoreAudioProps.string(object, kAudioProcessPropertyBundleID) ?? ""
            let playing = (CoreAudioProps.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0

            let owner = Self.owningApp(pid: pid, bundleID: bundleID, regularApps: regularApps)
            let key: String
            let name: String
            let icon: NSImage?
            if let owner {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                name = owner.localizedName ?? key
                icon = owner.icon
            } else {
                // Background helpers with no visible app: only list them while they make sound.
                guard playing || volumes[bundleID] != nil || muted.contains(bundleID) else { continue }
                key = bundleID.isEmpty ? "pid:\(pid)" : bundleID
                name = bundleID.split(separator: ".").last.map(String.init) ?? "Process \(pid)"
                icon = nil
            }

            if var group = groups[key] {
                group.processObjects.append(object)
                group.isPlaying = group.isPlaying || playing
                groups[key] = group
            } else {
                groups[key] = AudioApp(id: key, name: name, icon: icon, processObjects: [object], isPlaying: playing)
            }
        }

        // Show apps that are playing, or that have a custom level.
        return groups.values
            .filter { $0.isPlaying || volumes[$0.id] != nil || muted.contains($0.id) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// Maps helper processes (e.g. "com.google.Chrome.helper") to the app you see in the Dock.
    private static func owningApp(pid: pid_t, bundleID: String,
                                  regularApps: [NSRunningApplication]) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
            return app
        }
        guard !bundleID.isEmpty else { return nil }
        if bundleID.hasPrefix("com.apple.WebKit"),
           let safari = regularApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            return safari
        }
        return regularApps
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return bundleID.hasPrefix(id + ".") || bundleID == id
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    // MARK: Output device changes

    private var listening = false

    private func listenForOutputChanges() {
        guard !listening else { return }
        listening = true
        var addr = CoreAudioProps.address(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectAddPropertyListenerBlock(CoreAudioProps.system, &addr, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.outputChanged() }
        }
    }

    /// Headphones plugged in, AirPods connected...: rebuild every tap on the new output.
    private func outputChanged() {
        outputUID = CoreAudioProps.defaultOutputUID()
        taps.removeAll()
        for app in apps where effectiveGain(app.id) < 0.995 { apply(app) }
    }
}
