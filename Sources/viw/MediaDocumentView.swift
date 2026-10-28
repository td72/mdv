import AVFoundation
import AVKit
import AppKit

/// `DocumentView` for video and audio: an `AVPlayerView` (so what macOS can decode plays:
/// H.264 / HEVC in mp4 / mov / m4v, AAC / MP3 / WAV / AIFF / FLAC audio) with the vim keys on
/// top — Space plays / pauses, `j` / `k` seek 5 s, `d` / `u` 30 s, `h` / `l` one frame while
/// paused, `0` / `$` / `gg` / `G` / `50G` jump, `+` / `-` / `=` volume, `m` mutes, `r` rotates.
/// Formats the system cannot read (mkv, webm, avi, ogg) get a note instead of garbage.
final class MediaDocumentView: NSObject, DocumentView {
    private let root = VimMediaView(frame: NSRect(x: 0, y: 0, width: 880, height: 960))
    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let badge = StatusBadge(frame: .zero)
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var turns = 0
    private var duration: Double = 0
    private var isAudio = false
    private var unplayable: String?

    var view: NSView { root }
    var onOpenFile: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var commands: ViewerCommands? {
        get { root.commands }
        set { root.commands = newValue }
    }
    var helpSections: [KeyHelp.Section] { [KeyHelp.media] }

    var status: String? {
        if let unplayable { return unplayable }
        guard duration > 0 || player.currentItem != nil else { return nil }
        var s = "\(Self.clock(player.currentTime().seconds)) / \(Self.clock(duration))"
        if player.timeControlStatus != .playing { s += " ⏸" }
        if player.isMuted { s += " · muted" } else if player.volume < 0.99 { s += " · vol \(Int((player.volume * 100).rounded()))%" }
        return s
    }

    override init() {
        super.init()
        root.autoresizingMask = [.width, .height]
        root.onResize = { [weak self] in self?.relayout() }
        root.onWindowChange = { [weak self] visible in if !visible { self?.player.pause() } } // a hidden tab goes quiet
        playerView.player = player
        playerView.controlsStyle = .inline // the mouse gets the scrubber; keys come through `root`
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        root.addSubview(playerView)
        note.alignment = .center
        note.font = .systemFont(ofSize: 14)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        root.addSubview(note)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.statusChanged()
        }
        player.actionAtItemEnd = .pause
    }

    deinit {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func focus() { root.window?.makeFirstResponder(root) }

    func load(source: Source, kind: FileKind, theme: Theme, preserveScroll: Bool) {
        guard let url = source.url else { return }
        let keepTime = preserveScroll ? player.currentTime() : .zero
        let wasPlaying = player.timeControlStatus == .playing
        isAudio = { if case .audio = kind { return true } else { return false } }()
        unplayable = nil
        duration = 0
        note.isHidden = true
        playerView.isHidden = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.statusChanged() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard self.player.currentItem === item else { return }
            if !playable {
                self.unplayable = "Cannot play"
                self.note.stringValue = "\(url.lastPathComponent)\n\nmacOS cannot decode this file (\(url.pathExtension.lowercased())).\nmp4 / mov / m4v with H.264 or HEVC, and m4a / mp3 / wav / aiff / flac audio play here;\nmkv / webm / avi / ogg need another player."
                self.note.isHidden = false
                self.playerView.isHidden = true
                self.relayout()
                self.statusChanged()
                return
            }
            let d = (try? await asset.load(.duration)) ?? .zero
            self.duration = d.isNumeric ? d.seconds : 0
            if keepTime.seconds > 0 { await self.player.seek(to: keepTime) }
            self.relayout()
            if wasPlaying { self.player.play() } // a file opens paused (like QuickTime Player); a reload keeps playing
            self.statusChanged()
        }
        relayout()
    }

    private func statusChanged() {
        badge.update(status ?? "", in: root)
        onStatusChange?()
    }

    /// `m:ss` / `h:mm:ss`.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Layout (rotation swaps the player view's width and height)

    private func relayout() {
        let b = root.bounds
        note.frame = NSRect(x: 40, y: (b.height / 2 - 60).rounded(), width: b.width - 80, height: 120)
        let swapped = turns % 2 == 1
        let size = swapped ? NSSize(width: b.height, height: b.width) : b.size
        playerView.frameCenterRotation = 0
        playerView.frame = NSRect(x: ((b.width - size.width) / 2).rounded(), y: ((b.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        playerView.frameCenterRotation = CGFloat(-90 * turns)
        playerView.controlsStyle = turns == 0 ? .inline : .none // the scrubber would turn with the picture
        badge.update(status ?? "", in: root)
    }

    /// `r` / `R`: quarter turns (video only; audio has nothing to turn).
    func rotate(_ quarterTurns: Int) -> Bool {
        guard !isAudio, unplayable == nil else { return false }
        turns = ((turns + quarterTurns) % 4 + 4) % 4
        relayout()
        return true
    }

    // MARK: - Transport

    private func seek(by seconds: Double) {
        guard duration > 0 else { return }
        seek(to: player.currentTime().seconds + seconds)
    }

    private func seek(to seconds: Double) {
        let t = max(0, min(duration, seconds))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.statusChanged() }
    }

    /// Space.
    func togglePlayback() -> Bool {
        guard unplayable == nil, player.currentItem != nil else { return false }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if duration > 0, player.currentTime().seconds >= duration - 0.05 { seek(to: 0) } // Space at the end: from the top
            player.play()
        }
        statusChanged()
        return true
    }

    /// `m`.
    func toggleMute() {
        player.isMuted.toggle()
        statusChanged()
    }

    func scrollLines(_ n: Int) { seek(by: Double(n) * 5) }          // j / k: 5 s
    func scrollHalfPages(_ n: Int) { seek(by: Double(n) * 30) }     // d / u: 30 s
    func scrollPages(_ n: Int) { seek(by: Double(n) * 60) }         // ⌃f / ⌃b / PgDn / PgUp: 1 min (Space is play / pause)
    func scrollHorizontal(_ n: Int) {                               // h / l: a frame while paused; 0 / $: start / end
        if abs(n) >= 1_000_000 { seek(to: n < 0 ? 0 : duration); return }
        guard let item = player.currentItem else { return }
        if player.timeControlStatus == .playing { player.pause() }
        if isAudio { seek(by: Double(n) * 0.1) } else { item.step(byCount: n); statusChanged() }
    }
    func scrollToTop() { seek(to: 0) }
    func scrollToBottom() { seek(to: duration) }
    func scrollToPercent(_ percent: Int) { seek(to: duration * Double(percent) / 100) }

    func find() {}
    func filter() {}
    func findNext(reverse: Bool) {}
    func copySelection() {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL]) // the file for Finder / apps…
        NSPasteboard.general.setString(url.path, forType: .string) // …and its path for text fields
        Toast.show(in: root, "Copied file", detail: url.lastPathComponent)
    }
    func copyRow() { copySelection() }
    func clearSelection() {}
    func toggleDetail() {}
    func switchPane() {}
    func sortRows() {}
    func unsortRows() {}

    /// `+` / `-`: volume in steps of 10 %; `=`: back to 100 %.
    func zoomView(_ delta: Int) -> Bool {
        player.volume = max(0, min(1, (player.volume * 10 + Float(delta)).rounded() / 10))
        if player.volume > 0 { player.isMuted = false }
        statusChanged()
        return true
    }
    func resetZoomView() -> Bool {
        player.volume = 1
        player.isMuted = false
        statusChanged()
        return true
    }

    /// Debug: the frame at the current time.
    func snapshot(to path: String) {
        guard path != "/dev/null", let asset = player.currentItem?.asset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        guard let cg = try? gen.copyCGImage(at: player.currentTime(), actualTime: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}

/// Container that takes the vim keys for the player (AVPlayerView keeps its own mouse controls).
final class VimMediaView: NSView {
    weak var commands: ViewerCommands?
    var onResize: (() -> Void)?
    var onWindowChange: ((Bool) -> Void)?
    private var keys = VimKeyMap()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = commands, keys.handle(event, c) else { return super.keyDown(with: event) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    override func cancelOperation(_ sender: Any?) {}
}
