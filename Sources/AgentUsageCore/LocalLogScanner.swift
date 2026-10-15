import Foundation

/// One assistant API response as recorded in Claude Code's session logs.
public struct TokenEvent: Sendable, Equatable {
    public let date: Date
    public let model: String
    public let input: Int
    public let cacheCreate: Int
    public let cacheRead: Int
    public let output: Int
    public let thinking: Int
    public let isSidechain: Bool
    public let sessionId: String

    public init(date: Date, model: String, input: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0,
                output: Int = 0, thinking: Int = 0, isSidechain: Bool = false, sessionId: String = "") {
        self.date = date
        self.model = model
        self.input = input
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
        self.output = output
        self.thinking = thinking
        self.isSidechain = isSidechain
        self.sessionId = sessionId
    }

    /// Total prompt size the model saw for this request.
    public var contextTokens: Int { input + cacheCreate + cacheRead }
}

/// Incrementally tails `~/.claude/projects/**/*.jsonl` and keeps recent token events in memory.
///
/// Claude Code appends one JSON line per message; assistant lines carry `message.usage`.
/// A single response can be logged on several lines (one per content block) with the same
/// `message.id` + `requestId`, so events are de-duplicated on that pair.
public actor LocalLogScanner {
    public let root: URL
    private var offsets: [String: UInt64] = [:]
    private var events: [TokenEvent] = []
    private var seen: [String: Date] = [:]
    private var knownFiles: [URL] = []
    private var lastDirectoryWalk: Date = .distantPast

    /// Walking the whole tree is the expensive part; between walks only known files are
    /// checked (a size comparison each), which catches appends to active sessions.
    private let directoryWalkInterval: TimeInterval = 30
    private static let chunkSize = 1 << 20
    static let maxLineBytes = 16 << 20

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Reads any newly appended lines and returns every event at or after `since`.
    public func scan(since: Date, now: Date = Date()) -> [TokenEvent] {
        if now.timeIntervalSince(lastDirectoryWalk) >= directoryWalkInterval {
            knownFiles = jsonlFiles(modifiedAfter: since)
            lastDirectoryWalk = now
        }
        for file in knownFiles {
            readNewLines(of: file, since: since)
        }
        events.removeAll { $0.date < since }
        seen = seen.filter { $0.value >= since }
        let livePaths = Set(knownFiles.map(\.path))
        offsets = offsets.filter { livePaths.contains($0.key) }
        return events
    }

    private func jsonlFiles(modifiedAfter cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            result.append(url)
        }
        return result
    }

    private func readNewLines(of url: URL, since: Date) {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var offset = offsets[path] ?? 0
        if offset > size { offset = 0 } // file was truncated/rewritten
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)

        // Stream in fixed-size chunks so a large first read never balloons memory.
        // Only complete lines are consumed; a partially written trailing line is retried next scan.
        let newline = UInt8(ascii: "\n")
        var pending = Data()
        var consumed = offset
        var skippingOversizedLine = false
        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            autoreleasepool {
                pending.append(chunk)
                if skippingOversizedLine {
                    guard let end = pending.firstIndex(of: newline) else {
                        consumed += UInt64(pending.count)
                        pending = Data()
                        return
                    }
                    consumed += UInt64(pending.distance(from: pending.startIndex, to: end) + 1)
                    pending = Data(pending[pending.index(after: end)...])
                    skippingOversizedLine = false
                }
                if let lastNewline = pending.lastIndex(of: newline) {
                    let complete = pending[pending.startIndex...lastNewline]
                    for line in complete.split(separator: newline) {
                        ingest(line: Data(line), since: since)
                    }
                    consumed += UInt64(complete.count)
                    pending = Data(pending[pending.index(after: lastNewline)...])
                }
                // Usage records are a few KB; a line this long can't be one. Drop it instead
                // of buffering without bound.
                if pending.count > Self.maxLineBytes {
                    consumed += UInt64(pending.count)
                    pending = Data()
                    skippingOversizedLine = true
                }
            }
        }
        offsets[path] = consumed
    }

    private func ingest(line: Data, since: Date) {
        guard let parsed = Self.parseLine(line),
              parsed.event.date >= since,
              seen[parsed.key] == nil
        else { return }
        seen[parsed.key] = parsed.event.date
        events.append(parsed.event)
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    static func parseLine(_ line: Data) -> (key: String, event: TokenEvent)? {
        // Cheap pre-filter: most lines (user turns, attachments, snapshots) have no usage.
        guard line.range(of: usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = obj["timestamp"] as? String,
              let date = DateParsing.parse(timestamp)
        else { return nil }

        let model = message["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return nil }

        func int(_ dict: [String: Any]?, _ key: String) -> Int {
            guard let number = dict?[key] as? NSNumber else { return 0 }
            return Sanitize.tokenCount(number.doubleValue)
        }
        let details = usage["output_tokens_details"] as? [String: Any]

        let messageId = message["id"] as? String ?? UUID().uuidString
        let requestId = obj["requestId"] as? String ?? ""
        let event = TokenEvent(
            date: date,
            model: model,
            input: int(usage, "input_tokens"),
            cacheCreate: int(usage, "cache_creation_input_tokens"),
            cacheRead: int(usage, "cache_read_input_tokens"),
            output: int(usage, "output_tokens"),
            thinking: int(details, "thinking_tokens"),
            isSidechain: obj["isSidechain"] as? Bool ?? false,
            sessionId: obj["sessionId"] as? String ?? ""
        )
        return ("\(messageId):\(requestId)", event)
    }
}
