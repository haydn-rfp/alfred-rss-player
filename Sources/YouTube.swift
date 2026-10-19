import AppKit
import WebKit
import SwiftUI

/// Drives YouTube's official IFrame player inside a WKWebView.
///
/// The web view lives in an off-screen host window whenever the video isn't on screen,
/// so audio keeps playing when the floating window is hidden; VideoView borrows it.
@MainActor
final class YouTubeController: NSObject, WKScriptMessageHandler {
    /// (state, currentTime, duration). States: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    var onUpdate: ((Int, Double, Double) -> Void)?

    let webView: WKWebView
    private let hostWindow: NSWindow
    private var ready = false
    private var pending: String?
    private var active = false  // a video is loaded; the host window only exists on screen while this is true
    private static let offscreen = NSPoint(x: -5000, y: -5000)

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        hostWindow = NSWindow(contentRect: NSRect(origin: Self.offscreen, size: NSSize(width: 480, height: 270)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        // Invisible and click-through: macOS moves off-screen windows onto a display when monitors are
        // connected or disconnected, and this one must never show up as a stray black YouTube box.
        hostWindow.alphaValue = 0
        hostWindow.ignoresMouseEvents = true
        hostWindow.hasShadow = false
        hostWindow.isOpaque = false
        hostWindow.backgroundColor = .clear
        hostWindow.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostWindow.setFrameOrigin(Self.offscreen) }
        }
        controller.add(self, name: "yt")
        park()
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://alfredplayer.local/"))
    }

    /// Return the web view to the off-screen window (keeps playback alive while hidden).
    func park() {
        webView.removeFromSuperview()
        webView.frame = hostWindow.contentView?.bounds ?? webView.frame
        hostWindow.contentView = webView
        hostWindow.setFrameOrigin(Self.offscreen)
        // Only keep the (invisible) host window around while a video needs to keep playing
        if active { hostWindow.orderFrontRegardless() } else { hostWindow.orderOut(nil) }
    }

    func load(videoID: String, start: Double, rate: Float) {
        active = true
        if webView.window === hostWindow || webView.window == nil { park() }
        run("load('\(videoID)', \(start), \(rate))")
    }
    func play() { run("player.playVideo()") }
    func pause() { run("player.pauseVideo()") }
    func stop() {
        run("player && player.stopVideo && player.stopVideo()")
        active = false
        if webView.window === hostWindow { hostWindow.orderOut(nil) }
    }
    func seek(to seconds: Double) { run("player.seekTo(\(seconds), true)") }
    func setRate(_ r: Float) { run("player.setPlaybackRate(\(r))") }

    private func run(_ js: String) {
        guard ready else { pending = js; return }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            if body["ready"] != nil {
                ready = true
                if let p = pending { pending = nil; webView.evaluateJavaScript(p, completionHandler: nil) }
                return
            }
            let state = body["s"] as? Int ?? -1
            let time = body["t"] as? Double ?? 0
            let length = body["d"] as? Double ?? 0
            onUpdate?(state, time, length)
        }
    }

    private static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style>
    </head><body><div id="p"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
    var player, rate = 1;
    function post(m){ window.webkit.messageHandlers.yt.postMessage(m); }
    function onYouTubeIframeAPIReady(){
      player = new YT.Player('p', {width:'100%', height:'100%',
        playerVars:{playsinline:1, rel:0, modestbranding:1, origin:location.origin},
        events:{
          onReady:function(){ post({ready:1}); },
          onStateChange:function(e){ if(e.data==1){ try{player.setPlaybackRate(rate);}catch(x){} } tick(); }
        }});
    }
    function load(id, start, r){ rate = r; player.loadVideoById({videoId:id, startSeconds:start}); }
    function tick(){
      if(!player || !player.getPlayerState) return;
      post({s:player.getPlayerState(), t:player.getCurrentTime()||0, d:player.getDuration()||0});
    }
    setInterval(tick, 500);
    </script></body></html>
    """
}

/// Shows the YouTube web view inside SwiftUI, handing it back to the off-screen host when removed.
struct VideoView: NSViewRepresentable {
    let controller: YouTubeController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let web = controller.webView
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.webView.superview !== nsView {
            controller.webView.removeFromSuperview()
            controller.webView.frame = nsView.bounds
            nsView.addSubview(controller.webView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated { Player.shared.youtube.park() }
    }
}
