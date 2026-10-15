import SwiftUI

// MARK: - Shared pieces

/// Local view state. (The command-line SDK lacks the @State macro plugin, so views use this instead.)
final class LocalState: ObservableObject {
    @Published var hovering = false
    @Published var drag: Double?
}

func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

struct Artwork: View {
    @ObservedObject var player = Player.shared
    var size: CGFloat

    var body: some View {
        ZStack {
            if let image = player.artworkImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: player.track?.isVideo == true ? "play.rectangle.fill" : "waveform")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

/// Thin capsule scrubber, like the system Now Playing bar; grows slightly while hovered.
struct Scrubber: View {
    @ObservedObject var player = Player.shared
    @StateObject private var local = LocalState()

    var body: some View {
        let total = max(player.duration, 1)
        let value = local.drag ?? player.position
        let hovering = local.hovering
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary.opacity(hovering ? 0.85 : 0.6))
                        .frame(width: max(0, geo.size.width * CGFloat(min(value / total, 1))))
                }
                .frame(height: hovering ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        player.isScrubbing = true
                        local.drag = Double(max(0, min(g.location.x / geo.size.width, 1))) * total
                    }
                    .onEnded { _ in
                        if let v = local.drag { player.seek(to: v) }
                        local.drag = nil
                        player.isScrubbing = false
                    })
            }
            .frame(height: 10)
            HStack {
                Text(timeText(value))
                Spacer()
                Text("-" + timeText(max(0, player.duration - value)))
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { local.hovering = h } }
        .disabled(player.duration <= 0)
    }
}

struct ControlButton: View {
    var symbol: String
    var size: CGFloat = 15
    var action: () -> Void
    @StateObject private var local = LocalState()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2, height: size * 2)
                .background(Circle().fill(.primary.opacity(local.hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { local.hovering = $0 }
    }
}

struct Controls: View {
    @ObservedObject var player = Player.shared
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 2 : 10) {
            ControlButton(symbol: "gobackward.15", size: compact ? 12 : 14) { player.skip(by: -15) }
            ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: compact ? 16 : 20) { player.toggle() }
            ControlButton(symbol: "goforward.30", size: compact ? 12 : 14) { player.skip(by: 30) }
        }
        .disabled(player.track == nil)
    }
}

struct RateMenu: View {
    @ObservedObject var player = Player.shared
    var body: some View {
        Menu {
            ForEach(Player.rates, id: \.self) { r in
                Button { player.setRate(r) } label: {
                    if r == player.rate { Label(rateText(r), systemImage: "checkmark") } else { Text(rateText(r)) }
                }
            }
        } label: {
            Text(rateText(player.rate))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.primary.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
    func rateText(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
}

// MARK: - Floating mini player

struct MiniPlayerView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var window = PanelState.shared
    @StateObject private var local = LocalState()

    var body: some View {
        VStack(spacing: 10) {
            if player.track?.isVideo == true && window.showVideo {
                VideoView(controller: player.youtube)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            HStack(spacing: 12) {
                Artwork(size: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.track?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(player.track?.artist ?? "Choose an episode in Alfred RSS")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Controls(compact: true)
            }
            if player.track != nil {
                HStack(spacing: 8) {
                    Scrubber()
                    RateMenu().padding(.bottom, 13)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            if local.hovering {
                HStack(spacing: 4) {
                    if player.track?.isVideo == true {
                        CornerButton(symbol: window.showVideo ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                                     help: window.showVideo ? "Hide video" : "Show video") {
                            withAnimation(.spring(duration: 0.35)) { window.showVideo.toggle() }
                        }
                    }
                    if player.track != nil {
                        CornerButton(symbol: "stop.fill", help: "Stop") { player.stop(); PanelController.shared.hide() }
                    }
                    CornerButton(symbol: "xmark", help: "Hide (keeps playing)") { PanelController.shared.hide() }
                }
                .padding(8)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { local.hovering = h } }
        .animation(.spring(duration: 0.35), value: player.track?.isVideo)
        .padding(12)  // room for the window shadow
    }
}

struct CornerButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
