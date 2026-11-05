import Foundation
import Testing
@testable import AgentUsageCore

@Suite struct SourceInfoTests {
    private let valid: [String: Any] = [
        "AgentUsageSourceRepo": "/Users/me/agent-usage",
        "AgentUsageSourceCommit": "30b8de3a1f",
        "AgentUsageSourceBranch": "main",
    ]

    @Test func parsesStampedKeys() throws {
        let info = try #require(SourceInfo(infoDictionary: valid))
        #expect(info.repoPath.path == "/Users/me/agent-usage")
        #expect(info.commit == "30b8de3a1f")
        #expect(info.branch == "main")
    }

    @Test func missingKeysDisableTheFeature() {
        for key in valid.keys {
            var dict = valid
            dict[key] = nil
            #expect(SourceInfo(infoDictionary: dict) == nil)
        }
    }

    @Test func refusesValuesThatCouldActAsGitOptions() {
        var dict = valid
        dict["AgentUsageSourceBranch"] = "--upload-pack=evil"
        #expect(SourceInfo(infoDictionary: dict) == nil)
        dict = valid
        dict["AgentUsageSourceCommit"] = "--output=x"
        #expect(SourceInfo(infoDictionary: dict) == nil)
        dict = valid
        dict["AgentUsageSourceRepo"] = "relative/path"
        #expect(SourceInfo(infoDictionary: dict) == nil)
    }
}

@Suite struct GitHubRemoteTests {
    @Test(arguments: [
        "git@github.com:dean-clo3d/agent-usage-tracker.git",
        "https://github.com/dean-clo3d/agent-usage-tracker",
        "https://github.com/dean-clo3d/agent-usage-tracker.git",
        "https://github.com/dean-clo3d/agent-usage-tracker/",
        "ssh://git@github.com/dean-clo3d/agent-usage-tracker.git",
    ])
    func mapsToWebURL(remote: String) {
        #expect(GitHubRemote.webURL(fromRemote: remote)?.absoluteString
            == "https://github.com/dean-clo3d/agent-usage-tracker")
    }

    @Test(arguments: [
        "git@gitlab.com:o/r.git",
        "https://example.com/o/r",
        "https://github.com/o",
        "https://github.com/o/r/tree/main",
        "file:///tmp/repo.git",
        "/tmp/repo.git",
        "",
    ])
    func rejectsOtherRemotes(remote: String) {
        #expect(GitHubRemote.webURL(fromRemote: remote) == nil)
    }
}

@Suite struct CommitSummaryTests {
    @Test func parsesLogOutput() {
        let log = "aaa111\u{1f}Add update check\nbbb222\u{1f}Fix: a\u{1f}b in subject\n\n"
        #expect(CommitSummary.parse(log: log) == [
            CommitSummary(sha: "aaa111", subject: "Add update check"),
            CommitSummary(sha: "bbb222", subject: "Fix: a\u{1f}b in subject"),
        ])
    }

    @Test func emptyLogHasNoCommits() {
        #expect(CommitSummary.parse(log: "").isEmpty)
    }
}

@Suite struct GitClientTests {
    @discardableResult
    private func git(_ dir: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ dir: URL, _ message: String) throws -> String {
        try message.write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(dir, "add", ".")
        try git(dir, "commit", "-q", "-m", message)
        return try git(dir, "rev-parse", "HEAD")
    }

    private func source(_ repo: URL, _ commit: String) throws -> SourceInfo {
        try #require(SourceInfo(infoDictionary: [
            "AgentUsageSourceRepo": repo.path, "AgentUsageSourceCommit": commit, "AgentUsageSourceBranch": "main",
        ]))
    }

    @Test func reportsNewRemoteCommitsThenNothingOnceCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitclient-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("bare.git")
        let clone = root.appendingPathComponent("clone")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try git(bare, "init", "-q", "--bare", "-b", "main")
        try git(root, "clone", "-q", bare.path, clone.path)
        let a = try commit(clone, "commit A")
        try git(clone, "push", "-q", "origin", "HEAD:main")

        try git(root, "clone", "-q", bare.path, other.path)
        let b = try commit(other, "commit B")
        try git(other, "push", "-q", "origin", "HEAD:main")

        let client = GitClient()
        let pending = try #require(try await client.checkForUpdate(source: source(clone, a)))
        #expect(pending.remoteCommit == b)
        #expect(pending.commits == [CommitSummary(sha: b, subject: "commit B")])
        #expect(pending.compareURL == nil)

        #expect(try await client.checkForUpdate(source: source(clone, b)) == nil)
    }

    @Test func failsWhenTheRepoIsUnreachable() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let stamped = try source(missing, "abcdef1")
        await #expect(throws: GitError.self) { try await GitClient().checkForUpdate(source: stamped) }
    }
}
