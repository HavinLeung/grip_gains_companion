import UIKit

@Observable
final class ForceChartDataSource {
    /// Redraw rate; power saving mode lowers it (lets ProMotion displays refresh less often)
    var framesPerSecond = AppConstants.normalGraphFrameRate {
        didSet { displayLink?.setFrameRate(Float(framesPerSecond)) }
    }
    /// Power saving: stop redrawing once samples stop arriving, instead of scrolling the last
    /// value. The grace period covers batched notifications (a Progressor sends ~16 at once).
    var stopsScrollingWhenIdle = false {
        didSet { wakeDisplayLinkIfVisible() }
    }
    /// The view enables rendering only while the graph is visible in the active scene.
    /// Samples still accumulate while rendering is paused.
    var isRenderingEnabled = false {
        didSet {
            if isRenderingEnabled { needsUpdate = true }
            displayLink?.isPaused = !isRenderingEnabled
        }
    }
    static let scrollGracePeriod: TimeInterval = 1

    var isRenderingPaused: Bool { displayLink?.isPaused ?? true }

    /// Seconds of history to keep, or nil to keep the whole session (graph's "entire session"
    /// window). The graph reads up to 1 s before its window, so keep a little more than that.
    var retainedSeconds: TimeInterval? {
        didSet { trimHistory() }
    }
    private static let retentionMargin: TimeInterval = 2

    /// Raw samples — private, not read by views, no SwiftUI re-renders
    @ObservationIgnored private var rawHistory: [(timestamp: Date, force: Double)] = []

    /// Display snapshot — updated at most `framesPerSecond` times per second
    private(set) var displayHistory: [(timestamp: Date, force: Double)] = []
    /// The time the snapshot represents; the right edge of a scrolling window
    private(set) var displayDate = Date()

    @ObservationIgnored private var displayLink: DisplayLinkHelper?
    @ObservationIgnored private var needsUpdate = false
    @ObservationIgnored private var lastSampleArrival: Date?

    init() {
        displayLink = DisplayLinkHelper(framesPerSecond: Float(framesPerSecond)) { [weak self] in
            self?.tick()
        }
        displayLink?.isPaused = true
    }

    func addSample(timestamp: Date, force: Double) {
        rawHistory.append((timestamp: timestamp, force: force))
        lastSampleArrival = Date()
        needsUpdate = true
        wakeDisplayLinkIfVisible()
        // Trim in chunks (about once a second) rather than on every sample
        if let retained = retainedSeconds, let first = rawHistory.first,
           timestamp.timeIntervalSince(first.timestamp) > retained + Self.retentionMargin + 1 {
            trimHistory()
        }
    }

    private func trimHistory() {
        guard let retained = retainedSeconds, let last = rawHistory.last else { return }
        let cutoff = last.timestamp.addingTimeInterval(-(retained + Self.retentionMargin))
        let firstKept = rawHistory.firstIndex { $0.timestamp >= cutoff } ?? rawHistory.endIndex
        guard firstKept > 0 else { return }
        rawHistory.removeFirst(firstKept)
        needsUpdate = true
    }

    func clear() {
        rawHistory.removeAll()
        lastSampleArrival = nil
        needsUpdate = true
        wakeDisplayLinkIfVisible()
    }

    private func wakeDisplayLinkIfVisible() {
        if isRenderingEnabled { displayLink?.isPaused = false }
    }

    private func tick() {
        let now = Date()
        let streaming = lastSampleArrival.map { now.timeIntervalSince($0) < Self.scrollGracePeriod } ?? false
        guard needsUpdate || streaming || !stopsScrollingWhenIdle else {
            displayLink?.isPaused = true
            return
        }
        if needsUpdate {
            needsUpdate = false
            displayHistory = rawHistory
        }
        displayDate = now
    }

    deinit {
        displayLink = nil
    }
}

final class DisplayLinkHelper {
    private var displayLink: CADisplayLink?
    private let callback: () -> Void

    var isPaused: Bool {
        get { displayLink?.isPaused ?? true }
        set { displayLink?.isPaused = newValue }
    }

    // CADisplayLink retains its target; using self would keep the helper and timer alive.
    private final class Target: NSObject {
        weak var owner: DisplayLinkHelper?
        @objc func update() { owner?.callback() }
    }

    init(framesPerSecond: Float, callback: @escaping () -> Void) {
        self.callback = callback
        let target = Target()
        target.owner = self
        displayLink = CADisplayLink(target: target, selector: #selector(Target.update))
        setFrameRate(framesPerSecond)
        displayLink?.add(to: .main, forMode: .common)
    }

    func setFrameRate(_ framesPerSecond: Float) {
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: framesPerSecond / 2, maximum: framesPerSecond, preferred: framesPerSecond
        )
    }

    deinit {
        displayLink?.invalidate()
    }
}
