import AppKit
import CoreAudio
import Foundation

/// One row in the mixer.
struct AppEntry: Identifiable, Equatable {
    let id: String          // bundle identifier (or a fallback key)
    let name: String
    let icon: NSImage?
    var isPlaying: Bool
    var volume: Float
    var isMuted: Bool

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying && a.volume == b.volume && a.isMuted == b.isMuted
    }
}

private struct AppSetting: Codable {
    var volume: Float = 1
    var muted: Bool = false
    var isDefault: Bool { !muted && volume >= 0.995 }
}

private struct ProcessGroup {
    let id: String
    let name: String
    let icon: NSImage?
    var objects: [AudioObjectID]
    var isPlaying: Bool
}

// Private libsystem function that maps helper processes (e.g. "Google Chrome Helper",
// "com.apple.WebKit.GPU") to the app that is responsible for them.
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsiblePIDFn: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

final class Mixer: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []
    @Published private(set) var outputDeviceName: String = ""
    @Published private(set) var lastError: String?

    private var settings: [String: AppSetting] = [:]
    private var groups: [String: ProcessGroup] = [:]
    private var taps: [String: AppTap] = [:]
    private var seenPlaying: Set<String> = []
    /// Every regular (Dock) app that is running.
    private var runningApps: [String: (name: String, icon: NSImage?)] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Apps that have registered with Core Audio at some point (persisted), so they are listed
    /// as soon as they launch next time, before they initialise audio again.
    private var knownAudioApps: Set<String> = []
    /// Installed web browsers: always listed, since they can play sound at any moment.
    private var browsers: Set<String> = []
    private let knownAudioAppsKey = "knownAudioApps"

    private var processListListener: PropertyListener?
    private var deviceListener: PropertyListener?
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var refreshScheduled = false
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private let defaultsKey = "appSettings"

    init() {
        loadSettings()
        knownAudioApps = Set(UserDefaults.standard.stringArray(forKey: knownAudioAppsKey) ?? [])
        processListListener = PropertyListener(objectID: .systemObject,
                                               selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.scheduleRefresh()
        }
        deviceListener = PropertyListener(objectID: .systemObject,
                                          selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputDeviceChanged()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.identityCache[app.processIdentifier] = nil
                }
                self?.updateRunningApps()
                self?.scheduleRefresh()
            })
        }
        updateRunningApps()
        updateOutputDeviceName()
        refresh()
    }

    private func updateRunningApps() {
        var apps: [String: (name: String, icon: NSImage?)] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != selfPID && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier else { continue }
            apps[bundleID] = (Mixer.clean(app.localizedName ?? bundleID), app.icon)
        }
        runningApps = apps
        if let probe = URL(string: "https://example.com") {
            browsers = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe)
                .compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
    }

    /// Whether a running app belongs in the mixer.
    private func canPlayAudio(_ id: String) -> Bool {
        groups[id] != nil || knownAudioApps.contains(id) || browsers.contains(id)
            || !(settings[id]?.isDefault ?? true)
    }

    // MARK: - Public API (UI)

    func setVolume(_ volume: Float, for id: String) {
        var setting = settings[id] ?? AppSetting()
        setting.volume = volume >= 0.995 ? 1 : max(0, volume)
        settings[id] = setting
        if let tap = taps[id] { tap.gain = setting.volume }
        updateEntry(id) { $0.volume = setting.volume }
        apply(id)
        saveSettings()
    }

    func toggleMute(for id: String) {
        var setting = settings[id] ?? AppSetting()
        setting.muted.toggle()
        if !setting.muted && setting.volume <= 0.001 { setting.volume = 1 }
        settings[id] = setting
        updateEntry(id) { $0.isMuted = setting.muted; $0.volume = setting.volume }
        apply(id)
        saveSettings()
    }

    func resetAll() {
        settings.removeAll()
        saveSettings()
        for id in Array(taps.keys) { removeTap(id) }
        rebuildEntries()
    }

    /// Restore every app's normal audio path (called on quit).
    func shutdown() {
        for id in Array(taps.keys) { removeTap(id) }
        processListeners.values.forEach { $0.remove() }
        processListeners.removeAll()
        processListListener?.remove()
        deviceListener?.remove()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    // MARK: - Process discovery

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let objects = AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList)
        let current = Set(objects)

        // Keep a listener on every process so we know when it starts / stops playing.
        for (id, listener) in processListeners where !current.contains(id) {
            listener.remove()
            processListeners[id] = nil
        }
        for id in objects where processListeners[id] == nil {
            processListeners[id] = PropertyListener(objectID: id,
                                                    selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        var newGroups: [String: ProcessGroup] = [:]
        for object in objects {
            guard let pid = object.processPID, pid > 0, pid != selfPID else { continue }
            guard let identity = identify(pid: pid, audioBundleID: object.processBundleID) else { continue }
            let playing = object.processIsRunningOutput
            if var group = newGroups[identity.id] {
                group.objects.append(object)
                group.isPlaying = group.isPlaying || playing
                newGroups[identity.id] = group
            } else {
                newGroups[identity.id] = ProcessGroup(id: identity.id, name: identity.name, icon: identity.icon,
                                                      objects: [object], isPlaying: playing)
            }
        }
        for key in newGroups.keys { newGroups[key]?.objects.sort() }
        groups = newGroups
        for group in newGroups.values where group.isPlaying { seenPlaying.insert(group.id) }
        let newlyKnown = Set(newGroups.keys.filter { runningApps[$0] != nil }).subtracting(knownAudioApps)
        if !newlyKnown.isEmpty {
            knownAudioApps.formUnion(newlyKnown)
            UserDefaults.standard.set(Array(knownAudioApps), forKey: knownAudioAppsKey)
        }

        // Tear down taps whose app is gone, then (re)apply everything else.
        for id in Array(taps.keys) where groups[id] == nil { removeTap(id) }
        for id in groups.keys { apply(id) }
        rebuildEntries()
    }

    private var identityCache: [pid_t: (id: String, name: String, icon: NSImage?)?] = [:]

    private func identify(pid: pid_t, audioBundleID: String?) -> (id: String, name: String, icon: NSImage?)? {
        if let cached = identityCache[pid] { return cached }
        var responsible = responsiblePIDFn?(pid) ?? pid
        if responsible <= 0 { responsible = pid }
        var result: (id: String, name: String, icon: NSImage?)?
        if responsible == selfPID {
            result = nil
        } else if let app = NSRunningApplication(processIdentifier: responsible), let bundleID = app.bundleIdentifier {
            result = (bundleID, Mixer.clean(app.localizedName ?? bundleID), app.icon)
        } else if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            result = (bundleID, Mixer.clean(app.localizedName ?? bundleID), app.icon)
        } else if let bundleID = audioBundleID, !bundleID.isEmpty {
            result = (bundleID, Mixer.prettyName(forBundleID: bundleID), nil)
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let name = String(cString: buffer)
            result = name.isEmpty ? nil : ("proc:\(name)", name, nil)
        }
        // Drop cache entries for dead PIDs occasionally.
        if identityCache.count > 512 { identityCache.removeAll() }
        identityCache[pid] = result
        return result
    }

    /// Some apps (e.g. WhatsApp) put invisible direction marks in their names, which breaks sorting.
    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}")))
    }

    private static func prettyName(forBundleID bundleID: String) -> String {
        if bundleID == "com.apple.systemsoundserverd" { return "System Sounds" }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: - Applying settings

    private func apply(_ id: String) {
        guard let group = groups[id] else { removeTap(id); return }
        let setting = settings[id] ?? AppSetting()
        if setting.isDefault { removeTap(id); return }

        do {
            if let existing = taps[id], existing.processObjects != group.objects {
                // Create the replacement first so the app is never briefly un-muted.
                let replacement = try AppTap(processObjects: group.objects, name: group.name)
                existing.invalidate()
                taps[id] = replacement
            } else if taps[id] == nil {
                taps[id] = try AppTap(processObjects: group.objects, name: group.name)
            }
            guard let tap = taps[id] else { return }
            tap.gain = setting.muted ? 0 : setting.volume

            let shouldRun = !setting.muted && setting.volume > 0.001 && group.isPlaying
            if shouldRun {
                guard let device = AudioObjectID.defaultOutputDevice, let uid = device.deviceUID else { return }
                try tap.start(outputDeviceUID: uid)
            } else if setting.muted || setting.volume <= 0.001 {
                tap.destroyAggregate()   // fully muted: no audio thread, no aggregate device
            } else {
                tap.stop()               // idle: keep device for fast restart, no CPU
            }
            lastError = nil
        } catch {
            lastError = "\(group.name): \(error)"
            NSLog("Volume Mixer: \(error)")
        }
    }

    private func removeTap(_ id: String) {
        taps[id]?.invalidate()
        taps[id] = nil
    }

    private func outputDeviceChanged() {
        updateOutputDeviceName()
        for tap in taps.values { tap.destroyAggregate() }
        for id in taps.keys { apply(id) }
    }

    private func updateOutputDeviceName() {
        outputDeviceName = AudioObjectID.defaultOutputDevice?.objectName ?? "No output device"
    }

    // MARK: - Entries

    private func rebuildEntries() {
        var byID: [String: AppEntry] = [:]
        // Every running app that can make sound, whether or not it is playing right now…
        for (id, app) in runningApps where canPlayAudio(id) {
            let setting = settings[id] ?? AppSetting()
            byID[id] = AppEntry(id: id, name: app.name, icon: app.icon, isPlaying: false,
                                volume: setting.volume, isMuted: setting.muted)
        }
        // …plus background processes that are (or were) actually producing audio.
        for group in groups.values {
            let isRunningApp = runningApps[group.id] != nil
            guard isRunningApp || group.isPlaying || seenPlaying.contains(group.id)
                    || !(settings[group.id]?.isDefault ?? true) else { continue }
            let setting = settings[group.id] ?? AppSetting()
            byID[group.id] = AppEntry(id: group.id, name: runningApps[group.id]?.name ?? group.name,
                                      icon: runningApps[group.id]?.icon ?? group.icon, isPlaying: group.isPlaying,
                                      volume: setting.volume, isMuted: setting.muted)
        }
        let list = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if list != entries { entries = list }
    }

    private func updateEntry(_ id: String, _ change: (inout AppEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: data) else { return }
        settings = decoded.filter { !$0.value.isDefault }
    }

    private func saveSettings() {
        let toSave = settings.filter { !$0.value.isDefault }
        if let data = try? JSONEncoder().encode(toSave) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
