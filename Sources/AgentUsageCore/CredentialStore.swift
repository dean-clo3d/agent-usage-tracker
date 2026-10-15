import Foundation

/// Only what the app needs. The refresh token is deliberately not modelled: it is never
/// decoded into a Swift value, so it can't be retained, logged or sent by accident.
public struct OAuthCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

// Keep the token out of `print`, `dump`, string interpolation and debugger summaries.
extension OAuthCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OAuthCredential(accessToken: <redacted>, expiresAt: \(expiresAt.map(String.init(describing:)) ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessToken": "<redacted>", "expiresAt": expiresAt as Any], displayStyle: .struct)
    }
}

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
}

/// Reads the OAuth credential that Claude Code stores after `/login`.
///
/// Read-only by design: we never refresh the token ourselves, because rotating the
/// refresh token here would silently log Claude Code out. Claude Code refreshes it
/// whenever it runs, and we re-read it when ours expires or is rejected.
public enum CredentialStore {
    public static let keychainService = "Claude Code-credentials"

    public static func load() throws -> OAuthCredential {
        guard var raw = readKeychain() ?? readCredentialsFile() else {
            throw CredentialError.notFound
        }
        // Best-effort wipe of the raw JSON (it also contains the refresh token).
        defer { raw.resetBytes(in: 0..<raw.count) }
        return try parse(raw)
    }

    /// Shells out to `/usr/bin/security` (absolute path, no PATH lookup; no secrets in argv)
    /// rather than using SecItemCopyMatching: the item's ACL already trusts that binary
    /// (Claude Code writes through it), so no keychain prompt appears, and rebuilding this
    /// ad-hoc-signed app doesn't invalidate access.
    static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        // Minimal environment: nothing inherited from whoever launched us.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static let maxCredentialBytes = 64 * 1024

    /// Reads `~/.claude/.credentials.json` without following symlinks. The type and size
    /// are checked on the already-open descriptor, so the file can't be swapped in between.
    static func readCredentialsFile() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maxCredentialBytes
        else { return nil }
        return try? handle.read(upToCount: maxCredentialBytes)
    }

    private struct Envelope: Decodable {
        let claudeAiOauth: OAuth

        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
        }
    }

    public static func parse(_ data: Data) throws -> OAuthCredential {
        guard let oauth = try? JSONDecoder().decode(Envelope.self, from: data).claudeAiOauth,
              isPlausibleToken(oauth.accessToken)
        else {
            throw CredentialError.malformed
        }
        return OAuthCredential(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    /// Rejects empty tokens and anything with whitespace/control characters, which could
    /// otherwise smuggle extra lines into the Authorization header.
    static func isPlausibleToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 4096
            && token.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
    }
}
