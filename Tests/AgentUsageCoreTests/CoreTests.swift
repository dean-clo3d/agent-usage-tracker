import Foundation
import Testing
@testable import AgentUsageCore

// Trimmed copy of a real /api/oauth/usage response (Team seat, 2026-10-12).
private let sampleResponse = """
{
  "five_hour": {"utilization": 2.0, "resets_at": "2026-10-12T05:29:59.953021+00:00"},
  "seven_day": {"utilization": 15.0, "resets_at": "2026-10-12T02:59:59.953063+00:00"},
  "seven_day_opus": null,
  "extra_usage": {"is_enabled": false},
  "limits": [
    {"kind": "session", "group": "session", "percent": 2, "severity": "normal",
     "resets_at": "2026-10-12T05:29:59.953021+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_all", "group": "weekly", "percent": 15, "severity": "normal",
     "resets_at": "2026-10-12T02:59:59.953063+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 16, "severity": "normal",
     "resets_at": "2026-10-12T02:59:59.953227+00:00",
     "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
  ],
  "weekly_scoped_shares": [{"limit_index": 2, "used_percent_of_weekly": 8, "allowance_percent_of_weekly": 50}]
}
"""

private func date(_ s: String) -> Date { DateParsing.parse(s)! }

@Suite struct UsageParsingTests {
    @Test func mapsLimitsFromRealResponse() throws {
        let response = try UsageResponse.decode(Data(sampleResponse.utf8))
        let limits = UsageMapper.limits(from: response)

        #expect(limits.map(\.kind) == [.session, .weeklyAll, .weeklyScoped])
        #expect(limits.map(\.percent) == [2, 15, 16])
        #expect(limits[0].title == "현재 세션")
        #expect(limits[2].title == "주간 · Fable")
        #expect(limits[2].shortTitle == "Fable")
        #expect(limits[2].usedOfWeekly == 8)
        #expect(limits[2].allowanceOfWeekly == 50)
        #expect(limits[1].usedOfWeekly == nil)
    }

    @Test func fallsBackToFlatFields() throws {
        let json = #"{"five_hour": {"utilization": 40, "resets_at": "2026-10-12T05:00:00+00:00"}, "seven_day": {"utilization": 70}}"#
        let limits = UsageMapper.limits(from: try UsageResponse.decode(Data(json.utf8)))
        #expect(limits.map(\.kind) == [.session, .weeklyAll])
        #expect(limits[0].resetsAt == date("2026-10-12T05:00:00Z"))
        #expect(limits[1].resetsAt == nil)
    }

    @Test func parsesMicrosecondTimestamps() {
        let parsed = DateParsing.parse("2026-10-12T05:29:59.953021+00:00")
        let base = DateParsing.parse("2026-10-12T05:29:59+00:00")!
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince(base) - 0.953021) < 0.0001)
        #expect(DateParsing.parse("2026-10-12T01:21:29.567Z") != nil)
        #expect(DateParsing.parse("garbage") == nil)
    }

    @Test func windowKeyIgnoresSubSecondNoise() {
        let a = UsageLimit(id: "s", kind: .session, title: "", shortTitle: "", percent: 1,
                           resetsAt: date("2026-10-12T05:29:59.953021+00:00"))
        let b = UsageLimit(id: "s", kind: .session, title: "", shortTitle: "", percent: 5,
                           resetsAt: date("2026-10-12T05:29:59.991000+00:00"))
        #expect(a.windowKey == b.windowKey)
    }

    @Test func parsesCredentialJSON() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1791781623437,"subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#
        let credential = try CredentialStore.parse(Data(json.utf8))
        #expect(credential.accessToken == "tok")
        #expect(credential.subscriptionType == "team")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_791_781_623.437))
        #expect(throws: CredentialError.malformed) { try CredentialStore.parse(Data("{}".utf8)) }
    }
}

@Suite struct LogScannerTests {
    private func assistantLine(id: String, request: String, timestamp: String, model: String = "claude-opus-5-5",
                               input: Int = 10, cacheRead: Int = 1000, output: Int = 100, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"requestId":"\#(request)","timestamp":"\#(timestamp)","sessionId":"s1","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"output_tokens_details":{"thinking_tokens":40}}}}"#
    }

    @Test func parsesAssistantUsageLine() throws {
        let line = assistantLine(id: "m1", request: "r1", timestamp: "2026-10-12T01:21:29.567Z")
        let parsed = try #require(LocalLogScanner.parseLine(Data(line.utf8)))
        #expect(parsed.key == "m1:r1")
        #expect(parsed.event.output == 100)
        #expect(parsed.event.thinking == 40)
        #expect(parsed.event.contextTokens == 1010)
    }

    @Test func ignoresNonUsageAndSyntheticLines() {
        #expect(LocalLogScanner.parseLine(Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)) == nil)
        let synthetic = assistantLine(id: "m", request: "r", timestamp: "2026-10-12T01:00:00Z", model: "<synthetic>")
        #expect(LocalLogScanner.parseLine(Data(synthetic.utf8)) == nil)
    }

    @Test func tailsIncrementallyAndDeduplicates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = project.appendingPathComponent("s1.jsonl")

        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let first = assistantLine(id: "m1", request: "r1", timestamp: ts)
        // Same response logged twice (one line per content block) + a half-written line.
        try (first + "\n" + first + "\n" + "{\"type\":\"assi").write(to: file, atomically: true, encoding: .utf8)

        let scanner = LocalLogScanner(root: dir)
        var events = await scanner.scan(since: now.addingTimeInterval(-3600), now: now)
        #expect(events.count == 1)

        // Complete the partial line with a new response and append another.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let rest = String(assistantLine(id: "m2", request: "r2", timestamp: ts).dropFirst(#"{"type":"assi"#.count))
        try handle.write(contentsOf: Data((rest + "\n").utf8))
        try handle.close()

        events = await scanner.scan(since: now.addingTimeInterval(-3600), now: now.addingTimeInterval(1))
        #expect(events.count == 2)
    }
}

@Suite struct ActivityStatsTests {
    @Test func computesTotalsSharesAndBuckets() {
        let now = date("2026-10-12T03:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let events = [
            TokenEvent(date: now.addingTimeInterval(-30), model: "claude-opus-5-5", input: 100, cacheRead: 900, output: 100, thinking: 60, sessionId: "a"),
            TokenEvent(date: now.addingTimeInterval(-120), model: "claude-haiku-5-5", input: 100, output: 20, isSidechain: true, sessionId: "b"),
            TokenEvent(date: now.addingTimeInterval(-7200), model: "claude-opus-5-5", input: 50, output: 10, sessionId: "a"),
        ]
        let stats = ActivityStats.compute(events: events, now: now, sessionWindowStart: now.addingTimeInterval(-3600), calendar: calendar)

        #expect(stats.today.requests == 3)
        #expect(stats.sessionWindow.requests == 2)
        #expect(stats.today.output == 130)
        #expect(stats.modelShares.first?.name == "Opus 5.5")
        #expect(stats.activeSessionsLastHour == 2)
        #expect(stats.perMinute.last! > 0) // event 30s ago lands in the newest bucket
        #expect(stats.recentRatePerMinute > 0)
        #expect(stats.sidechainShare > 0 && stats.sidechainShare < 1)
        #expect(abs(stats.thinkingShare - 60.0 / 130.0) < 0.0001)
        // cache read 900 of 1150 prompt tokens (100+900 + 100 + 50)
        #expect(abs(stats.today.cacheHitRatio! - 900.0 / 1150.0) < 0.0001)
    }

    @Test func modelDisplayNames() {
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelName.display("claude-haiku-5-5") == "Haiku 5.5")
        #expect(ModelName.family("Fable 5.1") == "Fable")
    }
}

@Suite struct ProjectionTests {
    let now = date("2026-10-12T03:00:00Z")

    private func session(_ percent: Double, resetsIn: TimeInterval) -> UsageLimit {
        UsageLimit(id: "session", kind: .session, title: "현재 세션", shortTitle: "세션",
                   percent: percent, resetsAt: now.addingTimeInterval(resetsIn))
    }

    @Test func usesRecentSamplesWhenSpanIsLongEnough() throws {
        let limit = session(40, resetsIn: 4 * 3600)
        let samples = [UsageSample(date: now.addingTimeInterval(-30 * 60), percent: 30),
                       UsageSample(date: now, percent: 40)]
        let p = try #require(Projector.project(limit: limit, samples: samples, now: now))
        #expect(p.isRecent)
        #expect(abs(p.ratePerHour - 20) < 0.001)       // +10%p in 30 min
        #expect(p.exhaustsBeforeReset)                  // 60%p left at 20/h = 3h < 4h to reset
    }

    @Test func fallsBackToWindowAverage() throws {
        // Window opened 2h ago (resets in 3h), 10% used → 5%p/h → full in 18h, after reset.
        let limit = session(10, resetsIn: 3 * 3600)
        let p = try #require(Projector.project(limit: limit, samples: [], now: now))
        #expect(!p.isRecent)
        #expect(abs(p.ratePerHour - 5) < 0.001)
        #expect(!p.exhaustsBeforeReset)
    }

    @Test func noProjectionRightAfterWindowOpens() {
        let limit = session(1, resetsIn: 5 * 3600 - 60)
        #expect(Projector.project(limit: limit, samples: [], now: now) == nil)
    }
}

@Suite struct AlertPlannerTests {
    let now = date("2026-10-12T03:00:00Z")

    private func limit(_ percent: Double, kind: UsageLimit.Kind = .session, resetsIn: TimeInterval = 3600) -> UsageLimit {
        UsageLimit(id: kind.rawValue, kind: kind, title: "현재 세션", shortTitle: "세션",
                   percent: percent, resetsAt: now.addingTimeInterval(resetsIn))
    }

    private func plan(_ limits: [UsageLimit], previous: [UsageLimit] = [], fired: Set<String> = [],
                      settings: AlertSettings = AlertSettings(predictive: false),
                      projections: [String: Projection] = [:]) -> [UsageAlert] {
        AlertPlanner.plan(limits: limits, previous: previous, projections: projections,
                          settings: settings, alreadyFired: fired, now: now)
    }

    @Test func firesOnlyHighestCrossedThreshold() {
        let alerts = plan([limit(92)])
        #expect(alerts.count == 1)
        #expect(alerts[0].key.hasSuffix("|reached|90"))
        #expect(alerts[0].level == .critical)
    }

    @Test func doesNotRepeatFiredAlerts() {
        let first = plan([limit(76)])
        #expect(first.count == 1)
        let second = plan([limit(77)], fired: Set(first.map(\.key)))
        #expect(second.isEmpty)
    }

    @Test func approachingAlertWithinMargin() {
        let alerts = plan([limit(46)], fired: [])
        #expect(alerts.count == 1)
        #expect(alerts[0].key.hasSuffix("|near|50"))
        #expect(plan([limit(44)]).isEmpty)
    }

    @Test func respectsWatchedKindsAndMasterSwitch() {
        var settings = AlertSettings(predictive: false)
        settings.watchedKinds = [.weeklyAll]
        #expect(plan([limit(95)], settings: settings).isEmpty)
        settings = AlertSettings(enabled: false)
        #expect(plan([limit(95)], settings: settings).isEmpty)
    }

    @Test func predictiveAlertWhenPaceExhaustsBeforeReset() {
        let l = limit(40, resetsIn: 3 * 3600)
        let projection = Projection(ratePerHour: 30, fullAt: now.addingTimeInterval(2 * 3600),
                                    exhaustsBeforeReset: true, isRecent: true)
        let alerts = plan([l], settings: AlertSettings(thresholds: [90], approachMargin: 0, predictive: true),
                          projections: [l.id: projection])
        #expect(alerts.count == 1)
        #expect(alerts[0].key.hasSuffix("|predict"))
    }

    @Test func resetAlertAfterHittingTopThreshold() {
        let old = limit(95, resetsIn: -60)
        let fresh = limit(1, resetsIn: 5 * 3600)
        let alerts = plan([fresh], previous: [old])
        #expect(alerts.map { $0.key.hasSuffix("|reset") } == [true])
    }

    @Test func pruneDropsOldWindows() {
        let fresh = limit(10).windowKey + "|reached|50"
        let stale = limit(10, resetsIn: -3 * 86_400).windowKey + "|reached|50"
        #expect(AlertPlanner.prune(firedKeys: [fresh, stale, "junk"], now: now) == [fresh])
    }
}

@Suite struct TipEngineTests {
    let now = date("2026-10-12T03:00:00Z")

    @Test func paceTipWhenSessionWillRunOut() {
        let session = UsageLimit(id: "session", kind: .session, title: "현재 세션", shortTitle: "세션",
                                 percent: 70, resetsAt: now.addingTimeInterval(2 * 3600))
        let projection = Projection(ratePerHour: 40, fullAt: now.addingTimeInterval(45 * 60),
                                    exhaustsBeforeReset: true, isRecent: true)
        let tips = TipEngine.contextualTips(limits: [session], projections: ["session": projection], activity: nil, now: now)
        #expect(tips.first?.id == "pace-session")
    }

    @Test func activityDrivenTips() {
        var activity = ActivityStats()
        activity.today.requests = 50
        activity.today.input = 1_000_000
        activity.today.cacheRead = 1_000_000 // 50% cache hit, ~40K avg context
        activity.today.output = 50_000
        activity.today.thinking = 40_000
        activity.sidechainShare = 0.5
        activity.thinkingShare = 0.8
        activity.modelShares = [ModelShare(name: "Fable 5.1", share: 0.9)]
        let ids = Set(TipEngine.contextualTips(limits: [], projections: [:], activity: activity, now: now).map(\.id))
        #expect(ids.isSuperset(of: ["cache", "subagents", "thinking", "model-mix"]))
        #expect(!ids.contains("context"))
    }

    @Test func generalTipsHaveUniqueIds() {
        let ids = TipEngine.generalTips.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite struct FormattingTests {
    @Test func durations() {
        #expect(Formatting.duration(4 * 3600 + 11 * 60 + 5) == "4시간 11분")
        #expect(Formatting.duration(101 * 60) == "1시간 41분")
        #expect(Formatting.duration(30) == "1분 미만")
        #expect(Formatting.duration(2 * 86_400 + 3 * 3600) == "2일 3시간")
    }

    @Test func tokens() {
        #expect(Formatting.tokens(812) == "812")
        #expect(Formatting.tokens(34_500) == "34.5K")
        #expect(Formatting.tokens(1_200_000) == "1.2M")
    }
}

// MARK: - Security regressions

/// Serves a 302 from the API host to another host and records every request it sees.
private final class RedirectingProtocol: URLProtocol {
    nonisolated(unsafe) static var hostsSeen: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.hostsSeen.append(request.url?.host ?? "")
        if request.url?.host == "api.anthropic.com" {
            var next = request
            next.url = URL(string: "https://attacker.example/collect")
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "https://attacker.example/collect"])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(sampleResponse.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite(.serialized) struct SecurityTests {
    @Test func refusesRedirectsSoTheTokenIsNeverReplayed() async {
        RedirectingProtocol.hostsSeen = []
        let api = UsageAPI(session: UsageAPI.makeSession(protocolClasses: [RedirectingProtocol.self]))
        await #expect(throws: UsageAPIError.self) { try await api.fetch(accessToken: "secret") }
        #expect(RedirectingProtocol.hostsSeen == ["api.anthropic.com"])
    }

    @Test func sessionKeepsNothingOnDisk() {
        let config = UsageAPI.makeSession().configuration
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.urlCredentialStorage == nil)
    }

    @Test func credentialNeverPrintsToken() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRET","refreshToken":"sk-ant-ort01-SECRET","expiresAt":1}}"#
        let credential = try CredentialStore.parse(Data(json.utf8))
        var dumped = ""
        dump(credential, to: &dumped)
        for rendered in ["\(credential)", String(reflecting: credential), dumped] {
            #expect(!rendered.contains("SECRET"))
        }
    }

    @Test func rejectsTokensThatCouldInjectHeaders() {
        for bad in ["", "abc\r\nX-Evil: 1", "abc def", "tok\u{0}", "tök", String(repeating: "a", count: 5000)] {
            let json = #"{"claudeAiOauth":{"accessToken":"\#(bad.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{0}", with: "\\u0000"))"}}"#
            #expect(throws: CredentialError.malformed) { try CredentialStore.parse(Data(json.utf8)) }
        }
        #expect(CredentialStore.isPlausibleToken("sk-ant-oat01-AbC_123-xyz"))
    }

    @Test func oversizedLogLineIsSkippedWithoutBreakingLaterLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let good = #"{"type":"assistant","requestId":"r9","timestamp":"\#(ts)","sessionId":"s","message":{"id":"m9","model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
        var blob = Data(repeating: UInt8(ascii: "x"), count: LocalLogScanner.maxLineBytes + 3_000_000)
        blob.append(Data(("\n" + good + "\n").utf8))
        try blob.write(to: dir.appendingPathComponent("s.jsonl"))

        let events = await LocalLogScanner(root: dir).scan(since: now.addingTimeInterval(-3600), now: now)
        #expect(events.count == 1)
        #expect(events.first?.output == 2)
    }
}

@Suite struct HostileInputTests {
    @Test func nonFiniteAndHugePercentsDoNotCrash() throws {
        // JSON can't carry NaN, but it can carry 1e308 — which used to overflow Int().
        let json = #"{"limits":[{"kind":"session","percent":1e308,"resets_at":"2026-10-12T05:00:00Z"},{"kind":"weekly_all","percent":-5}]}"#
        let limits = UsageMapper.limits(from: try UsageResponse.decode(Data(json.utf8)))
        #expect(limits.map(\.percent) == [1000, 0])
        #expect(Formatting.percent(.nan) == "0%")
        #expect(Formatting.percent(.infinity) == "0%")
        #expect(Formatting.percent(1e300) == "1000%")
        #expect(Formatting.tokens(.nan) == "–")
        #expect(Formatting.duration(.infinity) == "–")
    }

    @Test func retryAfterIsAlwaysFiniteAndBounded() {
        #expect(Sanitize.retryAfter(TimeInterval("nan"), default: 120, cap: 900) == 120)
        #expect(Sanitize.retryAfter(-3, default: 120, cap: 900) == 120)
        #expect(Sanitize.retryAfter(.infinity, default: 120, cap: 900) == 120)
        #expect(Sanitize.retryAfter(1e9, default: 120, cap: 900) == 900)
        #expect(Sanitize.retryAfter(30, default: 120, cap: 900) == 30)
    }

    @Test func hugeTokenCountsCannotOverflowTotals() throws {
        let line = #"{"type":"assistant","requestId":"r","timestamp":"2026-10-12T01:00:00Z","message":{"id":"m","model":"x","usage":{"input_tokens":9.3e18,"output_tokens":-7,"cache_read_input_tokens":1e300}}}"#
        let event = try #require(LocalLogScanner.parseLine(Data(line.utf8))?.event)
        #expect(event.input == 1 << 40)
        #expect(event.output == 0)
        var totals = TokenTotals()
        for _ in 0..<1000 { totals.add(event) } // would trap without clamping
        #expect(totals.requests == 1000)
    }
}
