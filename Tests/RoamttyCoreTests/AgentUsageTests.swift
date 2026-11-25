import XCTest
@testable import RoamttyCore

final class AgentUsageTests: XCTestCase {
    func testParsesSessionUsageWithQuotasAndContext() {
        let raw = """
        agent=codex
        model=gpt-5.4
        ctx_used=164000
        ctx_limit=200000
        ctx_cache_read=104000
        ctx_cache_create=24000
        ctx_turn=36000
        sess_input=78000
        sess_output=44000
        sess_cache_read=1060000
        sess_cache_create=0
        q5h_rem=38.0
        q5h_reset=1795608000
        q7d_rem=59.2
        q7d_reset=1795900000
        """
        let u = AgentUsage.parseSession(raw)
        XCTAssertEqual(u?.agent, .codex)
        XCTAssertEqual(u?.formattedModel, "gpt-5.4")
        XCTAssertEqual(u?.contextPercent, 82)
        XCTAssertEqual(u?.contextRemaining, 36_000)
        XCTAssertEqual(u?.sessionTotalTokens, 1_182_000)
        XCTAssertEqual(u?.cacheHitPercent, 93)
        XCTAssertEqual(u?.quota5h?.remainingRounded, 38)
        XCTAssertEqual(u?.quota5h?.usedRounded, 62)
        XCTAssertEqual(u?.quota7d?.remainingRounded, 59)
        XCTAssertEqual(u?.quota7d?.usedRounded, 41)
    }

    func testDegradesGracefullyWithoutQuotasOrContext() {
        let raw = """
        agent=grok
        model=grok-4.7
        sess_input=120000
        sess_output=8000
        sess_cache_read=252000
        sess_cache_create=0
        """
        let u = AgentUsage.parseSession(raw)
        XCTAssertEqual(u?.agent, .grok)
        XCTAssertNil(u?.contextPercent)
        XCTAssertNil(u?.quota5h)
        XCTAssertNil(u?.quota7d)
        XCTAssertEqual(u?.sessionTotalTokens, 380_000)
        XCTAssertNil(CodingAgent.grok.compactCommand)
        XCTAssertEqual(CodingAgent.claude.compactCommand, "/compact")
        XCTAssertEqual(CodingAgent.codex.compactCommand, "/compact")
        XCTAssertEqual(CodingAgent.agy.compactCommand, "/compact")
    }

    func testParsesHostMultiAgentUsageSortedByTotalTokens() {
        let output = """
        range=7d
        agent=grok|1|120000|10000|250000|0||||
        agent=claude|3|200000|100000|3160000|0||||
        agent=codex|2|100000|50000|1650000|0|66.0|1795608000|81.0|1795900000
        """
        let host = AgentUsage.parseHost(output, requestedRange: .today)
        XCTAssertEqual(host.range, .week)
        XCTAssertEqual(host.agents.map(\.agent), [.claude, .codex, .grok])
        XCTAssertEqual(host.totalTokens, 5_640_000)
        XCTAssertEqual(host.cacheHitPercent, 92)
        XCTAssertEqual(host.agents[1].quota5h?.remainingRounded, 66)
        XCTAssertEqual(host.agents[1].quota7d?.remainingRounded, 81)
        XCTAssertNil(host.agents[2].quota5h)
    }

    func testFormatsTokensModelsAndResets() {
        XCTAssertEqual(AgentUsage.formatTokens(840), "840")
        XCTAssertEqual(AgentUsage.formatTokens(4_200), "4.2k")
        XCTAssertEqual(AgentUsage.formatTokens(164_000), "164k")
        XCTAssertEqual(AgentUsage.formatTokens(1_180_000), "1.18M")
        XCTAssertEqual(AgentUsage.formatTokens(1_540_000_000), "1.54B")
        XCTAssertEqual(AgentUsage.formatModelName("claude-opus-4-6-20260301"), "Opus 4.6")
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, english: false), "2h 14m 后重置")
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, english: true), "Resets in 2h 14m")
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, compact: true), "2h14m")
    }
}
