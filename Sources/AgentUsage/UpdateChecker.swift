import AgentUsageCore
import Foundation
import Observation

enum UpdateState: Equatable {
    case upToDate
    case available(PendingUpdate)
    case installing(PendingUpdate)
    case installFailed(PendingUpdate, message: String)

    var pending: PendingUpdate? {
        switch self {
        case .upToDate: return nil
        case .available(let update), .installing(let update), .installFailed(let update, _): return update
        }
    }
}

/// Source-based updates: looks for new commits in the clone this build came from, and on request
/// pulls and rebuilds in that same clone. Nothing is downloaded except by the user's own git.
@MainActor
@Observable
final class UpdateChecker {
    private(set) var state: UpdateState = .upToDate
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?

    /// Nil for builds without the Info.plist stamp (e.g. `swift run`), which disables updates.
    let source: SourceInfo?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let git = GitClient()
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let lastNotifiedKey = "lastNotifiedUpdateCommit"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Claude Usage/update.log")

    init(settings: AppSettings, infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        self.settings = settings
        source = SourceInfo(infoDictionary: infoDictionary)
    }

    func start() {
        guard source != nil, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                if self?.settings.checkForUpdates == true { await self?.check() }
                try? await Task.sleep(for: .seconds(6 * 3600), tolerance: .seconds(300))
            }
        }
    }

    /// A failed check (offline, auth) is silent and leaves the state as it was.
    func check() async {
        guard let source, !isChecking else { return }
        if case .installing = state { return }
        isChecking = true
        defer { isChecking = false }
        let result: PendingUpdate?
        do {
            result = try await git.checkForUpdate(source: source)
        } catch {
            return
        }
        lastCheckedAt = Date()
        guard let pending = result else {
            state = .upToDate
            return
        }
        if case .installFailed(let failed, _) = state, failed == pending { return }
        state = .available(pending)
        notifyOnce(pending)
    }

    func install() {
        guard let source, case let pending? = state.pending else { return }
        if case .installing = state { return }
        state = .installing(pending)
        do {
            let process = try makeInstallProcess(source)
            process.terminationHandler = { [weak self] finished in
                guard finished.terminationStatus != 0 else { return }
                Task { @MainActor in
                    self?.state = .installFailed(pending, message: "업데이트에 실패했어요. 작업 폴더에 변경이 있거나 브랜치가 갈라졌다면 터미널에서 직접 업데이트하세요. 로그: ~/Library/Logs/Claude Usage/update.log")
                }
            }
            try process.run()
        } catch {
            state = .installFailed(pending, message: "업데이트를 시작하지 못했어요. 터미널에서 직접 업데이트하세요.")
        }
    }

    /// Output goes to a file, not a pipe: build-app.sh kills this app before launching the new
    /// one, and a pipe with a dead reader would SIGPIPE the script mid-install.
    private func makeInstallProcess(_ source: SourceInfo) throws -> Process {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: Self.logURL.path) {
            fileManager.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: Self.logURL)
        try log.seekToEnd()
        try log.write(contentsOf: Data("\n=== \(Date()) update to origin/\(source.branch) ===\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The branch is passed as $1 so it is never parsed as shell syntax.
        process.arguments = ["-c", "git pull --ff-only origin \"$1\" && scripts/build-app.sh --install", "update", source.branch]
        process.currentDirectoryURL = source.repoPath
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func notifyOnce(_ pending: PendingUpdate) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.lastNotifiedKey) != pending.remoteCommit else { return }
        defaults.set(pending.remoteCommit, forKey: Self.lastNotifiedKey)
        NotificationService.shared.post(
            identifier: "update-\(pending.remoteCommit)",
            title: "새 버전이 있어요",
            body: "커밋 \(pending.commits.count)개 · \(pending.commits.first?.subject ?? "")"
        )
    }
}
