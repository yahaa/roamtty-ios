import XCTest
@testable import RoamttyCore

final class OutputHistoryTests: XCTestCase {
    private func rows(_ values: [String], columns: Int = 40) -> [HistoryRow] { values.map { HistoryRow(text: $0, columns: columns) } }
    private func chat(_ transcript: [String], end: Int, footer: String = "> input") -> [HistoryRow] {
        rows(["HEADER"] + Array(transcript[max(0, end - 6)..<end]) + Array(repeating: "", count: max(0, 6 - end)) + [footer])
    }

    func testInPlaceStreamingAndStyleUpdatesStayLive() {
        let history = OutputHistory()
        history.capture(rows(["Header", "old reply", "Prompt"]))
        history.capture(rows(["Header", "old reply 2", "Prompt"]))
        history.capture(rows(["Header", "new reply 2", "Prompt"]))
        history.capture([HistoryRow(text: "Header", columns: 40, style: 7)] + rows(["new reply 2", "Prompt"]))
        XCTAssertTrue(history.recorded.isEmpty)
        XCTAssertEqual(history.snapshot().map(\.text), ["Header", "new reply 2", "Prompt"])
        XCTAssertEqual(history.snapshot()[0].style, 7)
    }

    func testTranscriptScrollsBetweenFixedHeaderAndFooterOnceDespiteStreamingReads() {
        let transcript = (0..<30).map { "line \($0) of the answer" }, history = OutputHistory()
        for end in 1...30 {
            let partial = Array(transcript.prefix(end - 1)) + [String(transcript[end - 1].prefix(9))]
            history.capture(chat(partial, end: end, footer: "* Working \(end)s"))
            history.capture(chat(transcript, end: end, footer: "+ Working \(end)s"))
        }
        XCTAssertEqual(history.recorded.map(\.text), Array(transcript.prefix(24)))
        XCTAssertEqual(history.snapshot().dropFirst(24).map(\.text), ["HEADER"] + Array(transcript.suffix(6)) + ["+ Working 30s"])
    }

    func testBackAndForthReplayDoesNotDuplicateRecordedPassages() {
        let transcript = (0..<20).map { "message number \($0)" }, history = OutputHistory()
        for end in 1...20 { history.capture(chat(transcript, end: end)) }
        for end in stride(from: 19, through: 6, by: -1) { history.capture(chat(transcript, end: end)) }
        for end in 6...20 { history.capture(chat(transcript, end: end)) }
        history.capture(chat(transcript, end: 10))
        XCTAssertEqual(history.recorded.map(\.text), Array(transcript.prefix(14)))
        XCTAssertEqual(history.snapshot().map(\.text), Array(transcript.prefix(14)) + ["HEADER", "> input"])
    }

    func testClearedRegionsRecordWholeAnswerAndIgnoreBlankRepaint() {
        let history = OutputHistory()
        history.capture(rows(["HEADER", "first answer one", "first answer two", "first answer three", "", "> footer"]))
        history.capture(rows(["", "", ""]))
        history.capture(rows(["HEADER", "", "", "", "", "> footer"]))
        history.capture(rows(["HEADER", "second answer", "", "", "", "> footer"]))
        XCTAssertEqual(history.recorded.map(\.text), ["first answer one", "first answer two", "first answer three"])
    }

    func testSnapshotRetainsGridStylesCombiningCharactersAndColoredBlankRows() {
        let history = OutputHistory()
        let frame = [HistoryRow(text: "中e\u{301}🙂  ", columns: 8, styles: [1, 1, 2, 3, 3, 4, 4, 4], wrapped: true), HistoryRow(text: "        ", columns: 8, style: 9)]
        history.capture(frame)
        let snapshot = history.snapshot()
        history.capture(rows(["one", "two", "three"], columns: 20))
        XCTAssertEqual(snapshot, frame)
        XCTAssertTrue(history.recorded.isEmpty, "Resizing relays out live content; it does not evict the old frame")
        XCTAssertEqual(snapshot[0].style(at: 2), 2)
        XCTAssertEqual(snapshot[1].style(at: 7), 9)
    }

    func testSynchronizedOutputDefersPartialFramesButHasBoundedWait() {
        let history = OutputHistory()
        history.captureWhenIdle(rows(["A", "B", "C", "D"]), synchronized: false)
        history.captureBeforeChange(rows(["B", "C", "D", "E"]), synchronized: true)
        for _ in 0..<15 { history.captureWhenIdle(rows(["B", "C", "D", "E"]), synchronized: true) }
        XCTAssertEqual(history.snapshot().map(\.text), ["A", "B", "C", "D"])
        history.captureWhenIdle(rows(["B", "C", "D", "E"]), synchronized: true)
        XCTAssertEqual(history.snapshot().map(\.text), ["A", "B", "C", "D", "E"])
    }

    func testShellRepeatedOutputIsRetainedAndOldSnapshotsRemainFrozen() {
        let history = OutputHistory()
        history.capture(rows(["ok", "ok", "done 1"]), alternate: false)
        let snapshot = history.snapshot()
        history.capture(rows(["ok", "done 1", "ok"]), alternate: false)
        history.capture(rows(["done 1", "ok", "done 2"]), alternate: false)
        XCTAssertEqual(history.snapshot().map(\.text), ["ok", "ok", "done 1", "ok", "done 2"])
        XCTAssertEqual(snapshot.map(\.text), ["ok", "ok", "done 1"])
    }

    func testCharacterAndLineLimitsEvictWholePhysicalRows() {
        let history = OutputHistory(maxChars: 200, maxLines: 3)
        for index in 0..<1000 { history.capture(rows(["Reply \(index)", "Reply \(index + 1)"])) }
        XCTAssertEqual(history.recorded.map(\.text), ["Reply 996", "Reply 997", "Reply 998"])
        let small = OutputHistory(maxChars: 6, maxLines: 50)
        small.capture(rows(["😀😀", "a", "b"]), alternate: false)
        small.capture(rows(["a", "b", "c"]), alternate: false)
        small.capture(rows(["b", "c", "d"]), alternate: false)
        XCTAssertEqual(small.recorded.map(\.text), ["a"])
        XCTAssertLessThanOrEqual(small.recorded.reduce(0) { $0 + $1.cost }, 6)
        XCTAssertEqual(HistoryRow(text: "😀", columns: 2).cost, 3)
    }

    func testDefaultLimitsHoldAcrossLongRunningTerminal() {
        let history = OutputHistory()
        for index in 0..<50_005 { history.capture(rows(["row \(index)", "row \(index + 1)"]), alternate: false) }
        XCTAssertEqual(history.recorded.count, 50_000)
        XCTAssertEqual(history.recorded.first?.text, "row 4")
        let huge = String(repeating: "x", count: 2 * 1024 * 1024)
        history.capture(rows([huge, "anchor one", "anchor two"]), alternate: false)
        history.capture(rows(["anchor one", "anchor two", "anchor three"]), alternate: false)
        XCTAssertFalse(history.recorded.contains { $0.text == huge })
        XCTAssertLessThanOrEqual(history.recorded.reduce(0) { $0 + $1.cost }, 2 * 1024 * 1024)
    }
}
