import AppKit
import CoreAudio
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mixer: Mixer!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer = Mixer()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Volume Mixer")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MixerView(mixer: mixer))
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer?.shutdown()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// Note: taps and aggregate devices are created as *private*, so Core Audio removes them
// automatically if this process exits or crashes — apps always get their normal sound back.
// Diagnostic: `VolumeMixer --list` prints the apps currently known to Core Audio and exits.
if CommandLine.arguments.contains("--list") {
    let mixer = Mixer()
    print("Output device: \(mixer.outputDeviceName)")
    for entry in mixer.entries {
        print("\(entry.isPlaying ? "▶︎" : " ") \(entry.name)  [\(entry.id)]  volume=\(entry.volume) muted=\(entry.isMuted)")
    }
    if mixer.entries.isEmpty { print("(no apps playing audio)") }
    exit(0)
}

// Diagnostic: `VolumeMixer --selftest <outfile>` routes a running `afplay` through a tap at 50%
// and records the measured input/output peak levels.
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    var log = ""
    let objects = AudioObjectID.systemObject.readObjectList(kAudioHardwarePropertyProcessObjectList).filter { obj in
        guard let pid = obj.processPID else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, 256)
        return String(cString: buffer) == "afplay"
    }
    log += "afplay process objects: \(objects)\n"
    do {
        let tap = try AppTap(processObjects: objects, name: "selftest")
        tap.gain = 0.5
        guard let uid = AudioObjectID.defaultOutputDevice?.deviceUID else { throw CoreAudioError(status: -1, context: "no device") }
        try tap.start(outputDeviceUID: uid)
        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let p = tap.debugPeaks
            log += String(format: "in=%.4f out=%.4f\n", p.input, p.output)
        }
        tap.invalidate()
    } catch {
        log += "error: \(error)\n"
    }
    try? log.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
