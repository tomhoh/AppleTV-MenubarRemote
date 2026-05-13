import SwiftUI
import AppleTVProtocol

/// Compact banner that appears at the very top of the popover when the
/// Apple TV is playing something. Shows title + (artist · app) + a thin
/// elapsed/duration progress bar. Driven by `CompanionConnection.$nowPlaying`,
/// which is updated by the AirPlay tunnel.
struct NowPlayingBanner: View {
    @EnvironmentObject private var connection: CompanionConnection

    /// Re-rendered every second so the progress bar advances smoothly even
    /// when the TV isn't pushing fresh now-playing payloads. Driven by
    /// `info.liveElapsed()` which extrapolates from elapsedTime + anchor.
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let info = connection.nowPlaying, hasContent(info) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(primaryText(info))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                if let subtitle = subtitleText(info) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let duration = info.duration, duration > 0 {
                    progressBar(elapsed: info.liveElapsed(at: tick) ?? info.elapsedTime ?? 0,
                                duration: duration)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .overlay(
                Rectangle()
                    .fill(.separator)
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .onReceive(ticker) { tick = $0 }
        }
    }

    private func progressBar(elapsed: Double, duration: Double) -> some View {
        let progress = min(1.0, max(0.0, elapsed / duration))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(height: 2)
                Capsule().fill(Color.primary.opacity(0.7))
                    .frame(width: geo.size.width * progress, height: 2)
            }
        }
        .frame(height: 2)
        .padding(.top, 2)
    }

    private func hasContent(_ info: NowPlayingInfo) -> Bool {
        (info.title?.isEmpty == false) ||
        (info.artist?.isEmpty == false) ||
        (info.app?.isEmpty == false)
    }

    /// Show title preferentially; fall back to album or app name.
    private func primaryText(_ info: NowPlayingInfo) -> String {
        if let t = info.title, !t.isEmpty { return t }
        if let alb = info.album, !alb.isEmpty { return alb }
        if let app = info.app, !app.isEmpty { return app }
        return "Now Playing"
    }

    private func subtitleText(_ info: NowPlayingInfo) -> String? {
        var parts: [String] = []
        if let artist = info.artist, !artist.isEmpty { parts.append(artist) }
        if let app = info.app, !app.isEmpty,
           // Only add app if it's not already shown as the title.
           info.title?.caseInsensitiveCompare(app) != .orderedSame,
           !parts.contains(app) {
            parts.append(app)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
