import XCTest
@testable import GripGainsCompanion

final class ForceChartDataSourceTests: XCTestCase {

    func testDisplayLinkStopsAfterOwnerIsReleased() {
        var ticks = 0
        var helper: DisplayLinkHelper? = DisplayLinkHelper(framesPerSecond: 60) { ticks += 1 }
        weak var releasedHelper = helper
        waitForSnapshot()
        XCTAssertGreaterThan(ticks, 0)
        helper = nil
        XCTAssertNil(releasedHelper, "The run loop must not retain the display-link owner")
        let ticksAtRelease = ticks
        waitForSnapshot()
        XCTAssertEqual(ticks, ticksAtRelease, "Released graphs must stop scheduling display work")
    }

    private func addSamples(_ source: ForceChartDataSource, seconds: Int, start: Date) {
        for i in 0..<(seconds * 80) {
            source.addSample(timestamp: start.addingTimeInterval(Double(i) / 80), force: 20)
        }
    }

    /// The display snapshot is published on the next display link tick
    private func waitForSnapshot() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testWindowedHistoryKeepsOnlyWhatTheGraphCanShow() {
        let source = ForceChartDataSource()
        source.isRenderingEnabled = true
        source.retainedSeconds = 5
        let start = Date()
        addSamples(source, seconds: 30, start: start)
        waitForSnapshot()

        let history = source.displayHistory
        let span = history.last!.timestamp.timeIntervalSince(history.first!.timestamp)
        XCTAssertGreaterThanOrEqual(span, 6, "Window plus the graph's 1 s lead-in must be kept")
        XCTAssertLessThanOrEqual(span, 8.1, "Older samples should be trimmed")
    }

    func testEntireSessionKeepsEverything() {
        let source = ForceChartDataSource()
        source.isRenderingEnabled = true
        source.retainedSeconds = nil
        addSamples(source, seconds: 30, start: Date())
        waitForSnapshot()

        XCTAssertEqual(source.displayHistory.count, 30 * 80)
    }

    func testNarrowingTheWindowTrimsImmediately() {
        let source = ForceChartDataSource()
        source.isRenderingEnabled = true
        addSamples(source, seconds: 30, start: Date())
        source.retainedSeconds = 5
        waitForSnapshot()

        let history = source.displayHistory
        XCTAssertLessThanOrEqual(history.last!.timestamp.timeIntervalSince(history.first!.timestamp), 7.1)
    }

    func testHiddenGraphPausesRenderingButKeepsIncomingSamples() {
        let source = ForceChartDataSource()
        XCTAssertTrue(source.isRenderingPaused)
        source.addSample(timestamp: Date(), force: 20)
        waitForSnapshot()
        XCTAssertTrue(source.displayHistory.isEmpty)

        source.isRenderingEnabled = true
        waitForSnapshot()
        XCTAssertEqual(source.displayHistory.last?.force, 20)
        XCTAssertFalse(source.isRenderingPaused)

        source.isRenderingEnabled = false
        let pausedDate = source.displayDate
        source.addSample(timestamp: Date(), force: 30)
        waitForSnapshot()
        XCTAssertTrue(source.isRenderingPaused)
        XCTAssertEqual(source.displayDate, pausedDate)
        XCTAssertEqual(source.displayHistory.last?.force, 20)

        source.isRenderingEnabled = true
        waitForSnapshot()
        XCTAssertEqual(source.displayHistory.map(\.force), [20, 30])
        XCTAssertGreaterThan(source.displayDate, pausedDate)
    }

    func testPowerSavingPausesIdleTimerAndNewSamplesWakeIt() {
        let source = ForceChartDataSource()
        source.stopsScrollingWhenIdle = true
        source.isRenderingEnabled = true
        source.addSample(timestamp: Date(), force: 20)
        waitForSnapshot()
        RunLoop.main.run(until: Date().addingTimeInterval(ForceChartDataSource.scrollGracePeriod + 0.2))
        XCTAssertTrue(source.isRenderingPaused)
        let idleDate = source.displayDate
        waitForSnapshot()
        XCTAssertEqual(source.displayDate, idleDate)

        source.addSample(timestamp: Date(), force: 30)
        XCTAssertFalse(source.isRenderingPaused)
        waitForSnapshot()
        XCTAssertEqual(source.displayHistory.last?.force, 30)
        XCTAssertGreaterThan(source.displayDate, idleDate)

        source.clear()
        waitForSnapshot()
        XCTAssertTrue(source.displayHistory.isEmpty)
        XCTAssertTrue(source.isRenderingPaused)
        source.stopsScrollingWhenIdle = false
        waitForSnapshot()
        XCTAssertFalse(source.isRenderingPaused, "Normal mode must keep scrolling without new readings")
        let normalDate = source.displayDate
        waitForSnapshot()
        XCTAssertGreaterThan(source.displayDate, normalDate)
    }
}
