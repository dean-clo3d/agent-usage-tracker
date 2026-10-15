import Foundation

public struct Tip: Sendable, Equatable, Identifiable {
    public let id: String
    /// SF Symbol name.
    public let symbol: String
    public let title: String
    public let body: String
    /// Higher shows first. General tips are 0.
    public let priority: Int

    public init(id: String, symbol: String, title: String, body: String, priority: Int = 0) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.body = body
        self.priority = priority
    }
}

public enum TipEngine {
    /// Data-driven tips based on current limits and today's local activity, highest priority first.
    public static func contextualTips(
        limits: [UsageLimit],
        projections: [String: Projection],
        activity: ActivityStats?,
        now: Date
    ) -> [Tip] {
        var tips: [Tip] = []
        let session = limits.first { $0.kind == .session }
        let weekly = limits.first { $0.kind == .weeklyAll }

        // Pace: the session window runs out before it resets.
        if let session, let projection = projections[session.id], projection.exhaustsBeforeReset,
           let fullAt = projection.fullAt, let resetsAt = session.resetsAt, session.percent < 100 {
            tips.append(Tip(
                id: "pace-session", symbol: "speedometer",
                title: "이 속도면 \(Formatting.clock(fullAt, now: now))쯤 세션 한도 소진",
                body: "재설정은 \(Formatting.clock(resetsAt, now: now))이에요. 전체 코드 탐색·대규모 리팩터링 같은 무거운 작업은 재설정 이후로 미루고, 지금은 범위가 좁은 작업 위주로 진행하세요.",
                priority: 100
            ))
        }

        // Weekly budget: spread what's left over the remaining days.
        if let weekly, weekly.percent >= 50, weekly.percent < 100, let resetsAt = weekly.resetsAt {
            let daysLeft = resetsAt.timeIntervalSince(now) / 86_400
            if daysLeft >= 1 {
                let perDay = (100 - weekly.percent) / daysLeft
                tips.append(Tip(
                    id: "budget-weekly", symbol: "calendar.badge.clock",
                    title: "주간 한도 \(Formatting.percent(weekly.percent)) · \(Formatting.duration(resetsAt.timeIntervalSince(now))) 남음",
                    body: "재설정까지 하루 평균 \(String(format: "%.0f", perDay))%p 이내로 쓰면 끊기지 않아요.",
                    priority: weekly.percent >= 80 ? 90 : 60
                ))
            }
        }

        // A model-scoped weekly limit (e.g. Fable) is filling faster than the overall one.
        for scoped in limits where scoped.kind == .weeklyScoped && scoped.percent >= 30 {
            let pressure: Bool
            if let used = scoped.usedOfWeekly, let allowance = scoped.allowanceOfWeekly, allowance > 0 {
                pressure = used / allowance >= 0.6
            } else {
                pressure = scoped.percent > (weekly?.percent ?? 0)
            }
            guard pressure else { continue }
            tips.append(Tip(
                id: "scoped-\(scoped.id)", symbol: "arrow.triangle.branch",
                title: "\(scoped.shortTitle) 주간 한도가 먼저 찰 수 있어요",
                body: "\(scoped.shortTitle) 사용률 \(Formatting.percent(scoped.percent)). 단순 수정·질문은 /model 로 다른 모델로 바꾸고, \(scoped.shortTitle)는 설계·어려운 디버깅에 아껴 두세요.",
                priority: 80
            ))
        }

        guard let activity else { return tips.sorted { $0.priority > $1.priority } }
        let today = activity.today

        // Heavy model dominating the mix.
        if let top = activity.modelShares.first, top.share >= 0.75, today.requests >= 20 {
            let family = ModelName.family(top.name)
            if ["Opus", "Fable"].contains(family) {
                tips.append(Tip(
                    id: "model-mix", symbol: "cpu",
                    title: "오늘 사용량의 \(Formatting.percent(top.share * 100))가 \(top.name)",
                    body: "파일 이름 바꾸기, 간단한 테스트 추가, 문서 질문 같은 작업은 /model sonnet 이나 haiku 로 충분해요. 서브에이전트에는 model: haiku 를 지정할 수 있어요.",
                    priority: 50
                ))
            }
        }

        // Low prompt-cache hit rate.
        if let hit = today.cacheHitRatio, hit < 0.75, today.requests >= 20 {
            tips.append(Tip(
                id: "cache", symbol: "arrow.triangle.2.circlepath",
                title: "캐시 적중률 \(Formatting.percent(hit * 100))로 낮은 편",
                body: "대화 도중 CLAUDE.md·MCP 설정·모델을 바꾸거나, 오래 쉬었다 재개하면 프롬프트 캐시가 깨져요. 같은 작업은 한 세션에서 이어가세요.",
                priority: 55
            ))
        }

        // Large average context per request.
        let windowContext = activity.sessionWindow.requests >= 10 ? activity.sessionWindow.averageContext : nil
        if let avg = windowContext ?? today.averageContext, avg >= 120_000, today.requests >= 10 {
            tips.append(Tip(
                id: "context", symbol: "text.append",
                title: "요청당 평균 컨텍스트 \(Formatting.tokens(avg)) 토큰",
                body: "매 요청마다 대화 전체가 다시 전송돼요. 주제가 바뀌면 /clear, 긴 작업 중에는 /compact 로 줄이세요. /context 로 무엇이 차지하는지 확인할 수 있어요.",
                priority: 70
            ))
        }

        // Subagents eating the budget.
        if activity.sidechainShare >= 0.4, today.requests >= 20 {
            tips.append(Tip(
                id: "subagents", symbol: "person.3",
                title: "오늘 사용량의 \(Formatting.percent(activity.sidechainShare * 100))가 서브에이전트",
                body: "서브에이전트는 각자 컨텍스트를 새로 채워요. 위치를 아는 파일은 직접 지정하고, 병렬 에이전트 수를 줄이면 크게 아낄 수 있어요.",
                priority: 45
            ))
        }

        // Thinking-heavy output.
        if activity.thinkingShare >= 0.5, today.output >= 20_000 {
            tips.append(Tip(
                id: "thinking", symbol: "brain",
                title: "출력 토큰의 \(Formatting.percent(activity.thinkingShare * 100))가 thinking",
                body: "단순한 작업에서는 /effort 를 낮추면 생각 토큰이 줄어요. 어려운 문제에서만 높이세요.",
                priority: 40
            ))
        }

        return tips.sorted { $0.priority > $1.priority }
    }

    /// Evergreen advice, rotated in the panel.
    public static let generalTips: [Tip] = [
        Tip(id: "g-clear", symbol: "eraser",
            title: "관련 없는 작업은 /clear 후 시작",
            body: "이전 대화가 매 요청마다 함께 전송돼요. 새 주제면 대화를 비우는 게 가장 큰 절약입니다."),
        Tip(id: "g-compact", symbol: "rectangle.compress.vertical",
            title: "긴 작업 중엔 /compact",
            body: "'/compact 결정사항과 남은 할 일만 유지'처럼 무엇을 남길지 지시할 수도 있어요."),
        Tip(id: "g-specific", symbol: "scope",
            title: "구체적으로 요청하기",
            body: "'버그 고쳐줘'보다 파일·함수·재현 방법을 알려주면 탐색에 쓰는 토큰이 확 줄어요."),
        Tip(id: "g-at-file", symbol: "at",
            title: "@파일 로 위치 직접 지정",
            body: "어디를 봐야 하는지 알면 @path/to/file 로 바로 알려주세요. 불필요한 검색을 건너뜁니다."),
        Tip(id: "g-claudemd", symbol: "doc.text",
            title: "CLAUDE.md는 짧게",
            body: "매 요청에 포함돼요. 핵심 규칙만 남기고 가끔 필요한 내용은 별도 문서로 빼세요."),
        Tip(id: "g-mcp", symbol: "puzzlepiece.extension",
            title: "안 쓰는 MCP 서버 끄기",
            body: "도구 정의도 컨텍스트를 차지해요. /mcp 와 /context 로 확인해 보세요."),
        Tip(id: "g-plan", symbol: "map",
            title: "큰 작업은 Plan 모드로 먼저 합의",
            body: "Shift+Tab 으로 Plan 모드. 방향이 틀린 구현을 되돌리는 비용이 훨씬 커요."),
        Tip(id: "g-output", symbol: "text.line.last.and.arrowtriangle.forward",
            title: "긴 출력은 필요한 부분만",
            body: "빌드·테스트 로그는 tail, grep 으로 잘라서 보게 하세요. 전체 로그는 컨텍스트를 빠르게 채워요."),
        Tip(id: "g-model", symbol: "slider.horizontal.3",
            title: "작업에 맞는 모델 고르기",
            body: "간단한 수정·질문은 /model 로 Sonnet이나 Haiku를 쓰고, 상위 모델은 어려운 문제에 아껴 두세요."),
        Tip(id: "g-effort", symbol: "dial.medium",
            title: "/effort 로 생각량 조절",
            body: "단순 작업은 effort를 낮추면 thinking 토큰이 줄어요."),
        Tip(id: "g-reset", symbol: "clock.arrow.circlepath",
            title: "재설정 직후에 무거운 작업 시작",
            body: "세션 한도는 5시간 창이에요. 큰 작업을 창이 열릴 때 시작하면 중간에 끊길 일이 줄어요."),
        Tip(id: "g-cache", symbol: "arrow.triangle.2.circlepath",
            title: "대화 중간에 설정 바꾸지 않기",
            body: "CLAUDE.md·MCP·모델을 바꾸면 프롬프트 캐시가 깨져 같은 내용을 다시 비싸게 보내요."),
        Tip(id: "g-memory", symbol: "brain.head.profile",
            title: "반복되는 지적은 한 줄로 기록",
            body: "같은 설명을 매번 하지 말고 CLAUDE.md나 메모리에 남겨 두세요."),
        Tip(id: "g-subagent", symbol: "person.2",
            title: "서브에이전트는 넓은 탐색에만",
            body: "파일 하나 읽는 일에 서브에이전트를 쓰면 컨텍스트를 새로 채우느라 오히려 비싸요."),
    ]
}
