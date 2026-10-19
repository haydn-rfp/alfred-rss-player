import SwiftUI
import AppKit
import Combine

// MARK: - Floating panel

@MainActor
final class PanelState: ObservableObject {
    static let shared = PanelState()
    @Published var visible = false
    @Published var showVideo = true
}

/// A borderless, always-on-top panel that doesn't steal focus and follows you across Spaces.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 384, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // SwiftUI glass draws its own; a window shadow would be rectangular
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
}

/// The one player window. It opens attached under the menu-bar icon and stays until hidden;
/// drag it anywhere to detach it, and it then shows/hides where you left it.
@MainActor
final class PanelController {
    static let shared = PanelController()
    private let panel = FloatingPanel()
    private let hosting: NSHostingView<MiniPlayerView>
    private var movingProgrammatically = false
    private var userDragged = false

    /// True once the user has dragged the window away from the menu bar.
    private(set) var detached: Bool {
        get { UserDefaults.standard.bool(forKey: "panelDetached") }
        set { UserDefaults.standard.set(newValue, forKey: "panelDetached") }
    }

    private init() {
        hosting = NSHostingView(rootView: MiniPlayerView())
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setFrameAutosaveName("AlfredPlayerPanel")
        hosting.postsFrameChangedNotifications = true
        // Keep the top edge fixed when the window grows for video
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: hosting, queue: .main) { _ in
            MainActor.assumeIsolated { PanelController.shared.fitToContent() }
        }
        // A move only counts as the user's when the mouse button is down — macOS also moves windows
        // itself when displays are connected or disconnected, and those moves mustn't detach it.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = PanelController.shared
                if !c.movingProgrammatically, c.panel.isVisible, NSEvent.pressedMouseButtons & 1 != 0 { c.userDragged = true }
            }
        }
        // When a drag ends: snap back under the icon if dropped near it, otherwise stay where it was put.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated { PanelController.shared.dragEnded() }
            return event
        }
        // Displays connected, disconnected or rearranged: put the window somewhere sensible again.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {  // let the menu bar settle first
                MainActor.assumeIsolated { PanelController.shared.screensChanged() }
            }
        }
        // A position saved on a display that's no longer connected
        if detached && !isOnScreen(panel.frame) { detached = false }
    }

    private func dragEnded() {
        guard userDragged else { return }
        userDragged = false
        if nearStatusItem() { attachToStatusItem() } else { detached = true; keepOnScreen() }
    }

    /// Dropped with its top close to the menu-bar icon?
    private func nearStatusItem() -> Bool {
        guard let anchor = StatusItemController.shared.iconFrame else { return false }
        let f = panel.frame
        return abs(f.maxY - anchor.minY) < 60 && abs(f.midX - anchor.midX) < 160
    }

    private func screensChanged() {
        if detached { keepOnScreen() } else { attachToStatusItem() }
    }

    private func isOnScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -16, dy: -16).contains(rect) }
    }

    /// Move the window fully onto the screen it's mostly on (or the main screen).
    private func keepOnScreen() {
        let f = panel.frame
        guard !isOnScreen(f) else { return }
        let screen = NSScreen.screens.max { a, b in
            a.visibleFrame.intersection(f).width * a.visibleFrame.intersection(f).height <
            b.visibleFrame.intersection(f).width * b.visibleFrame.intersection(f).height
        } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let x = min(max(f.minX, v.minX), v.maxX - f.width)
        let y = min(max(f.minY, v.minY), v.maxY - f.height)
        setFrame(NSRect(x: x, y: y, width: f.width, height: f.height))
    }

    private func setFrame(_ rect: NSRect) {
        movingProgrammatically = true
        panel.setFrame(rect, display: true, animate: false)
        movingProgrammatically = false
    }

    func fitToContent() {
        let size = hosting.fittingSize
        guard size.height > 0, abs(panel.frame.height - size.height) > 0.5 || abs(panel.frame.width - size.width) > 0.5 else { return }
        let top = panel.frame.maxY
        setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height))
    }

    /// Place the window just below the menu-bar icon, kept on screen.
    func attachToStatusItem() {
        guard let anchor = StatusItemController.shared.iconFrame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        // the window has 12pt of transparent padding for its shadow; tuck it up under the menu bar
        setFrame(NSRect(x: x, y: anchor.minY - size.height + 8, width: size.width, height: size.height))
        detached = false
    }

    func show() {
        if detached { fitToContent() } else { attachToStatusItem() }
        panel.orderFrontRegardless()
        PanelState.shared.visible = true
    }

    func hide() {
        panel.orderOut(nil)
        PanelState.shared.visible = false
    }

    func toggle() { PanelState.shared.visible ? hide() : show() }

    func reattach() {
        attachToStatusItem()
        if !PanelState.shared.visible { show() }
    }
}

// MARK: - Menu-bar icon

/// Click: show/hide the player. Right-click (or ⌥-click): Stop, Attach to menu bar, Quit.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables = Set<AnyCancellable>()

    var iconFrame: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private override init() {
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Alfred RSS Player"
        }
        let player = Player.shared
        player.$track.combineLatest(player.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] track, playing in self?.updateIcon(hasTrack: track != nil, playing: playing) }
            .store(in: &cancellables)
    }

    private func updateIcon(hasTrack: Bool, playing: Bool) {
        let name = !hasTrack ? "headphones" : (playing ? "waveform" : "pause.fill")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Alfred RSS Player")
        image?.isTemplate = true
        item.button?.image = image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            PanelController.shared.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let player = Player.shared
        if player.track != nil {
            menu.addItem(withTitle: player.isPlaying ? "Pause" : "Play", action: #selector(togglePlay), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: PanelState.shared.visible ? "Hide Player" : "Show Player", action: #selector(togglePanel), keyEquivalent: "").target = self
        if PanelController.shared.detached {
            menu.addItem(withTitle: "Attach to Menu Bar", action: #selector(reattach), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Alfred RSS Player", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)  // opens the menu attached to the icon
        item.menu = nil                 // so left-click goes back to toggling the player
    }

    @objc private func togglePlay() { Player.shared.toggle() }
    @objc private func stop() { Player.shared.stop(); PanelController.shared.hide() }
    @objc private func togglePanel() { PanelController.shared.toggle() }
    @objc private func reattach() { PanelController.shared.reattach() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - URL commands
//
//   alfredplayer://play?url=<audio or YouTube link>&title=&artist=&artwork=<url or file path>&id=
//   alfredplayer://toggle | pause | resume | stop | show | hide | skip?by=30 | speed?rate=1.5

@MainActor
enum Commands {
    static func handle(_ url: URL) {
        guard url.scheme == "alfredplayer" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let player = Player.shared

        switch url.host ?? "" {
        case "play":
            guard let raw = q("url"), let link = URL(string: raw) else { return }
            var artwork: URL?
            if let a = q("artwork") { artwork = a.hasPrefix("/") ? URL(fileURLWithPath: a) : URL(string: a) }
            let track = Track(id: q("id") ?? raw, url: link, title: q("title") ?? link.lastPathComponent,
                              artist: q("artist") ?? link.host ?? "", artwork: artwork,
                              youtubeID: Track.youtubeID(from: link))
            player.play(track)
            PanelController.shared.show()
        case "toggle": player.toggle()
        case "pause": player.pause()
        case "resume", "play-pause-resume": player.resume()
        case "stop": player.stop()
        case "show": PanelController.shared.show()
        case "hide": PanelController.shared.hide()
        case "window": PanelController.shared.toggle()
        case "skip": player.skip(by: Double(q("by") ?? "30") ?? 30)
        case "speed": if let r = Float(q("rate") ?? "") { player.setRate(r) }
        default: break
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        MainActor.assumeIsolated { _ = Player.shared; _ = StatusItemController.shared; _ = PanelController.shared }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(Commands.handle) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AlfredPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // The menu-bar icon and the player window are managed in AppKit (StatusItemController / PanelController);
    // SwiftUI needs at least one scene, so this is an empty Settings scene that's never shown.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
