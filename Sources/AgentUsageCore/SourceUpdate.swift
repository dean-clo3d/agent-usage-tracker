import Foundation

/// Where this build came from, stamped into Info.plist by `scripts/build-app.sh`.
/// Absent for builds that aren't from a git checkout (e.g. `swift run`), which disables updates.
public struct SourceInfo: Equatable, Sendable {
    public let repoPath: URL
    public let commit: String
    public let branch: String

    public init?(infoDictionary: [String: Any]) {
        guard let path = infoDictionary["AgentUsageSourceRepo"] as? String, path.hasPrefix("/"),
              let commit = infoDictionary["AgentUsageSourceCommit"] as? String,
              let branch = infoDictionary["AgentUsageSourceBranch"] as? String,
              // These end up in git argv, so a value that looks like an option or a non-sha is refused.
              commit.count >= 7, commit.allSatisfy(\.isHexDigit),
              !branch.isEmpty, !branch.hasPrefix("-")
        else { return nil }
        repoPath = URL(fileURLWithPath: path, isDirectory: true)
        self.commit = commit
        self.branch = branch
    }
}

public enum GitHubRemote {
    /// Browsable https URL for a GitHub remote, or nil for any other host or shape.
    public static func webURL(fromRemote remote: String) -> URL? {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if remote.hasPrefix("git@github.com:") {
            path = remote.dropFirst("git@github.com:".count)
        } else if let url = URL(string: remote), url.host == "github.com",
                  ["https", "ssh"].contains(url.scheme) {
            path = url.path.dropFirst()
        } else {
            return nil
        }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed.contains) }) else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }
}

public struct CommitSummary: Equatable, Sendable {
    public let sha: String
    public let subject: String

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }

    /// Parses `git log --format=%H%x1f%s` output, newest first.
    public static func parse(log: String) -> [CommitSummary] {
        log.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            return CommitSummary(sha: String(fields[0]), subject: String(fields[1]))
        }
    }
}

public struct PendingUpdate: Equatable, Sendable {
    public let remoteCommit: String
    public let commits: [CommitSummary]
    public let compareURL: URL?

    public init(remoteCommit: String, commits: [CommitSummary], compareURL: URL?) {
        self.remoteCommit = remoteCommit
        self.commits = commits
        self.compareURL = compareURL
    }
}

public enum GitError: Error, Equatable {
    case failed(status: Int32)
    case timedOut
}

/// Runs the system git against the user's own clone. No other network access exists here.
public struct GitClient: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// Fetches the tracked branch and lists the commits the build doesn't have yet.
    public func checkForUpdate(source: SourceInfo) async throws -> PendingUpdate? {
        _ = try await run(source.repoPath, ["fetch", "--quiet", "origin", source.branch])
        let log = try await run(source.repoPath, [
            "log", "--format=%H%x1f%s", "\(source.commit)..origin/\(source.branch)",
        ])
        let commits = CommitSummary.parse(log: log)
        guard let newest = commits.first else { return nil }
        let remote = try? await run(source.repoPath, ["remote", "get-url", "origin"])
        let web = remote.flatMap(GitHubRemote.webURL(fromRemote:))
        let compare = web.flatMap { URL(string: "\($0.absoluteString)/compare/\(source.commit)...\(newest.sha)") }
        return PendingUpdate(remoteCommit: newest.sha, commits: commits, compareURL: compare)
    }

    private func run(_ repo: URL, _ arguments: [String]) async throws -> String {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try Self.runBlocking(repo, arguments, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ repo: URL, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A SIGTERM exit means the watchdog fired: nothing else here sends signals.
        let timedOut = process.terminationReason == .uncaughtSignal
        watchdog.cancel()

        if timedOut { throw GitError.timedOut }
        guard process.terminationStatus == 0 else { throw GitError.failed(status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self)
    }
}
