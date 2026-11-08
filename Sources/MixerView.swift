import ServiceManagement
import SwiftUI

struct MixerView: View {
    @ObservedObject var mixer: Mixer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)

            if mixer.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.zzz")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("No apps running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Open an app and it will show up here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(mixer.entries) { entry in
                            AppRow(entry: entry, mixer: mixer)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(mixer.entries.count) * 46, 460))
            }

            if let error = mixer.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }

            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Volume Mixer").font(.headline)
                Text(mixer.outputDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Reset") { mixer.resetAll() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Set every app back to 100%")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

private struct AppRow: View {
    let entry: AppEntry
    let mixer: Mixer

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .opacity(entry.isMuted ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if entry.isPlaying {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .help("Playing audio")
                    }
                    Spacer()
                    Text(entry.isMuted ? "Muted" : "\(Int((entry.volume * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button {
                        mixer.toggleMute(for: entry.id)
                    } label: {
                        Image(systemName: muteIcon)
                            .frame(width: 18)
                            .foregroundStyle(entry.isMuted ? Color.red : Color.primary)
                    }
                    .buttonStyle(.borderless)
                    .help(entry.isMuted ? "Unmute" : "Mute")

                    Slider(value: Binding(
                        get: { Double(entry.isMuted ? 0 : entry.volume) },
                        set: { newValue in
                            if entry.isMuted { mixer.toggleMute(for: entry.id) }
                            mixer.setVolume(Float(newValue), for: entry.id)
                        }
                    ), in: 0...1)
                    .controlSize(.small)
                }
            }
        }
    }

    private var muteIcon: String {
        if entry.isMuted || entry.volume <= 0.001 { return "speaker.slash.fill" }
        if entry.volume < 0.34 { return "speaker.wave.1.fill" }
        if entry.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
