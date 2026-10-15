import AppKit
import AVFoundation
import MediaPlayer
import Combine

/// Something to play: a podcast/audio file, or a YouTube video.
struct Track: Codable, Equatable {
    var id: String
    var url: URL
    var title: String
    var artist: String
    var artwork: URL?
    var youtubeID: String?

    var isVideo: Bool { youtubeID != nil }

    /// YouTube video id from watch / youtu.be / shorts / live links.
    static func youtubeID(from url: URL) -> String? {
        let s = url.absoluteString
        let patterns = [#"youtu\.be/([\w-]{11})"#, #"[?&]v=([\w-]{11})"#, #"/(?:shorts|live|embed)/([\w-]{11})"#]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) {
                let match = String(s[r])
                return String(match.suffix(11))
            }
        }
        return nil
    }
}

/// Plays one track at a time through AVPlayer (audio) or the YouTube controller (video),
/// publishes state for the UI, and keeps macOS Now Playing / media keys in sync.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var artworkImage: NSImage?
    @Published var isScrubbing = false

    let youtube = YouTubeController()
    private let audio = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    static let rates: [Float] = [0.8, 1.0, 1.2, 1.5, 1.75, 2.0]

    private init() {
        audio.automaticallyWaitsToMinimizeStalling = true
        timeObserver = audio.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                     queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.audioTick(time) }
        }
        youtube.onUpdate = { [weak self] state, time, length in
            self?.videoTick(state: state, time: time, length: length)
        }
        setupRemoteCommands()
    }

    // MARK: Commands

    func play(_ new: Track) {
        savePosition()
        stopCurrent()
        track = new
        position = 0
        duration = 0
        loadArtwork(for: new)
        let resume = savedPosition(for: new.id)
        if let vid = new.youtubeID {
            youtube.load(videoID: vid, start: resume, rate: rate)
        } else {
            let item = AVPlayerItem(url: new.url)
            audio.replaceCurrentItem(with: item)
            if resume > 0 { audio.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finished() }
            }
            audio.playImmediately(atRate: rate)
        }
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        guard track != nil else { return }
        if track?.isVideo == true { youtube.pause() } else { audio.pause() }
        isPlaying = false
        savePosition(force: true)
        updateNowPlaying()
    }

    func resume() {
        guard track != nil else { return }
        if track?.isVideo == true { youtube.play() } else { audio.playImmediately(atRate: rate) }
        isPlaying = true
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        if track?.isVideo == true {
            youtube.seek(to: target)
        } else {
            audio.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: position + seconds) }

    func setRate(_ new: Float) {
        rate = new
        if track?.isVideo == true { youtube.setRate(new) } else if isPlaying { audio.rate = new }
        updateNowPlaying()
    }

    func stop() {
        savePosition(force: true)
        stopCurrent()
        track = nil
        isPlaying = false
        position = 0
        duration = 0
        artworkImage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        StateFile.write(nil, isPlaying: false, position: 0, duration: 0)
    }

    private func stopCurrent() {
        audio.pause()
        audio.replaceCurrentItem(with: nil)
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        youtube.stop()
    }

    private func finished() {
        if let t = track { Positions.clear(t.id) }
        isPlaying = false
        position = duration
        updateNowPlaying()
    }

    // MARK: Ticks

    private func audioTick(_ time: CMTime) {
        guard track?.isVideo == false, !isScrubbing else { return }
        position = time.seconds.isFinite ? time.seconds : 0
        if let d = audio.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        tickCommon()
    }

    private func videoTick(state: Int, time: Double, length: Double) {
        guard track?.isVideo == true else { return }
        if !isScrubbing { position = time }
        if length > 0 { duration = length }
        if state == 0 { finished(); return }  // ended
        let playing = state == 1 || state == 3  // playing / buffering
        if playing != isPlaying, state != 3 { isPlaying = playing; updateNowPlaying() }
        tickCommon()
    }

    private func tickCommon() {
        savePosition()
        StateFile.write(track, isPlaying: isPlaying, position: position, duration: duration)
        // Keep elapsed time fresh for Control Centre without rebuilding everything every tick
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Resume positions

    private func savedPosition(for id: String) -> Double {
        let p = Positions.get(id)
        return p > 10 ? p - 3 : 0  // step back a few seconds for context
    }

    private func savePosition(force: Bool = false) {
        guard let t = track, force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        if duration > 0, position > duration - 30 { Positions.clear(t.id) } else { Positions.set(t.id, position) }
    }

    // MARK: Artwork

    private func loadArtwork(for t: Track) {
        artworkImage = nil
        let source = t.artwork ?? t.youtubeID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg") }
        guard let url = source else { return }
        if url.isFileURL {
            artworkImage = NSImage(contentsOf: url)
            updateNowPlaying()
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.track == t else { return }
                    self.artworkImage = image
                    self.updateNowPlaying()
                }
            }
        }.resume()
    }

    // MARK: Now Playing + media keys

    private func updateNowPlaying() {
        guard let t = track else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: t.isVideo ? MPNowPlayingInfoMediaType.video.rawValue
                                                         : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        StateFile.write(t, isPlaying: isPlaying, position: position, duration: duration)
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.resume() }; return .success }
        c.pauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.toggle() }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.skip(by: 30) }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { _ in MainActor.assumeIsolated { Player.shared.skip(by: -15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { Player.shared.seek(to: e.positionTime) }
            return .success
        }
    }
}

/// Where each track was left off, so episodes resume.
enum Positions {
    private static let key = "positions"
    static func get(_ id: String) -> Double { (UserDefaults.standard.dictionary(forKey: key)?[id] as? Double) ?? 0 }
    static func set(_ id: String, _ seconds: Double) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[id] = seconds
        if all.count > 500 { all = Dictionary(uniqueKeysWithValues: all.suffix(400).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(all, forKey: key)
    }
    static func clear(_ id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// A small JSON file other tools (Alfred) can read to show what's playing.
enum StateFile {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred RSS Player", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()
    private static var last = ""

    static func write(_ t: Track?, isPlaying: Bool, position: Double, duration: Double) {
        var dict: [String: Any] = ["playing": isPlaying, "position": Int(position), "duration": Int(duration),
                                   "updated": Int(Date().timeIntervalSince1970)]
        if let t {
            dict["id"] = t.id; dict["title"] = t.title; dict["artist"] = t.artist
            dict["url"] = t.url.absoluteString; dict["video"] = t.isVideo
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8), text != last else { return }
        last = text
        try? data.write(to: url, options: .atomic)
    }
}
