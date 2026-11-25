import SwiftUI
import AppKit

/// Per-app volume sliders.
struct SoundSection: View {
    @ObservedObject var mixer: AppVolumeMixer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !AppVolumeMixer.isSupported {
                unsupported
            } else {
                Text("Turn individual apps up or down. Apps appear here while they play sound.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if mixer.apps.isEmpty {
                    empty
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(mixer.apps) { app in
                                AppVolumeRow(app: app, mixer: mixer)
                            }
                        }
                    }
                }

                if let notice = mixer.notice {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11))
                        Text(notice)
                            .font(.system(size: 10.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                }

                Spacer(minLength: 0)

                HStack {
                    Text("Needs the \"System Audio Recording\" permission the first time. Driftline never records or saves audio.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Reset all") { mixer.resetAll() }
                        .controlSize(.small)
                        .help("Put every app back to 100%")
                }
            }
        }
        .onAppear { mixer.setVisible(true) }
        .onDisappear { mixer.setVisible(false) }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing is playing")
                .font(.system(size: 12, weight: .medium))
            Text("Play music, a video or a call, and the app will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var unsupported: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Per-app volume needs macOS 14.2 or later")
                .font(.system(size: 12, weight: .medium))
            Text("Update macOS in System Settings → General → Software Update to use it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var mixer: AppVolumeMixer

    var body: some View {
        let muted = mixer.isMuted(app)
        let volume = muted ? 0 : mixer.volume(for: app)

        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.driftDown)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { volume },
                    set: { mixer.setVolume($0, for: app) }
                ), in: 0...1)
                .controlSize(.small)
                .tint(Color.driftDown)
            }

            Button {
                mixer.toggleMute(app)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
