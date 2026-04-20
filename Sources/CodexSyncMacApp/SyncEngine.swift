import Darwin
import Foundation
import SQLite3

struct CurrentProviderInfo: Sendable {
    let provider: String
    let implicit: Bool
}

struct ProviderCounts: Sendable {
    var sessions: [String: Int]
    var archivedSessions: [String: Int]

    static let empty = ProviderCounts(sessions: [:], archivedSessions: [:])

    func total(in directory: SessionDirectory) -> Int {
        switch directory {
        case .sessions:
            return sessions.values.reduce(0, +)
        case .archivedSessions:
            return archivedSessions.values.reduce(0, +)
        }
    }

    func entries(in directory: SessionDirectory) -> [(String, Int)] {
        let source: [String: Int]
        switch directory {
        case .sessions:
            source = sessions
        case .archivedSessions:
            source = archivedSessions
        }

        return source.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    }
}

struct BackupSummary: Sendable {
    let count: Int
    let totalBytes: Int64

    static let empty = BackupSummary(count: 0, totalBytes: 0)
}

struct BackupPruneResult: Sendable {
    let backupRoot: String
    let deletedCount: Int
    let remainingCount: Int
    let freedBytes: Int64
}

struct StatusSnapshot: Sendable {
    let codexHome: String
    let currentProvider: CurrentProviderInfo
    let configuredProviders: [String]
    let rolloutCounts: ProviderCounts
    let sqliteCounts: ProviderCounts?
    let backupRoot: String
    let backupSummary: BackupSummary
}

enum ProviderSource: String, CaseIterable, Codable, Sendable {
    case config
    case rollout
    case sqlite
    case manual

    var title: String {
        switch self {
        case .config:
            return "Config"
        case .rollout:
            return "Rollout"
        case .sqlite:
            return "SQLite"
        case .manual:
            return "Manual"
        }
    }
}

struct ProviderOption: Identifiable, Hashable, Sendable {
    let id: String
    let sources: [ProviderSource]
    let isCurrentProvider: Bool
    let isManual: Bool
    let isSaved: Bool
}

struct SyncResult: Sendable {
    let codexHome: String
    let targetProvider: String
    let previousProvider: String
    let backupDir: String
    let changedSessionFiles: Int
    let skippedLockedRolloutFiles: [String]
    let sqliteRowsUpdated: Int
    let sqlitePresent: Bool
    let rolloutCountsBefore: ProviderCounts
    var configUpdated: Bool
    let autoPruneResult: BackupPruneResult?
    let autoPruneWarning: String?
    let startedAt: Date
    let finishedAt: Date

    var durationText: String {
        String(format: "%.2fs", finishedAt.timeIntervalSince(startedAt))
    }
}

struct RestoreResult: Sendable {
    let codexHome: String
    let backupDir: String
    let targetProvider: String
    let createdAt: Date?
    let changedSessionFiles: Int
}

struct BackupEntry: Identifiable, Hashable, Sendable {
    let path: String
    let targetProvider: String
    let createdAt: Date
    let changedSessionFiles: Int
    let totalBytes: Int64

    var id: String { path }
}

enum SessionDirectory: String, CaseIterable, Sendable {
    case sessions = "sessions"
    case archivedSessions = "archived_sessions"

    var title: String {
        switch self {
        case .sessions:
            return "Sessions"
        case .archivedSessions:
            return "Archived"
        }
    }
}

private struct SessionChange: Sendable {
    let path: String
    let threadID: String?
    let directory: SessionDirectory
    let originalFirstLine: String
    let originalSeparator: String
    let originalOffset: Int
    let originalFileLength: Int64
    let updatedFirstLine: String
}

private struct SessionApplyResult: Sendable {
    let appliedCount: Int
    let appliedPaths: [String]
    let skippedPaths: [String]
}

private struct SessionChangeCollection: Sendable {
    let changes: [SessionChange]
    let lockedPaths: [String]
    let providerCounts: ProviderCounts
}

private struct FirstLineRecord: Sendable {
    let firstLine: String
    let separator: String
    let offset: Int
}

private struct LockHandle {
    let path: String

    func release() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private struct BackupMetadataFile: Codable {
    let version: Int
    let namespace: String
    let codexHome: String
    let targetProvider: String
    let createdAt: Date
    let dbFiles: [String]
    let changedSessionFiles: Int
}

private struct SessionBackupManifest: Codable {
    let version: Int
    let namespace: String
    let codexHome: String
    let targetProvider: String
    let createdAt: Date
    let files: [SessionBackupManifestEntry]
}

private struct SessionBackupManifestEntry: Codable, Sendable {
    let path: String
    let originalFirstLine: String
    let originalSeparator: String
}

enum ProviderSyncEngine {
    static let defaultProvider = "openai"
    static let backupNamespace = "provider-sync"
    static let defaultBackupRetentionCount = 5
    static let stateDatabaseBasename = "state_5.sqlite"
    static let lockDirectoryName = "provider-sync.lock"

    static func defaultCodexHome() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .path
    }

    static func backupsRoot(for codexHome: String) -> String {
        URL(fileURLWithPath: codexHome)
            .appendingPathComponent("backups_state")
            .appendingPathComponent(backupNamespace)
            .path
    }

    static func normalizeCodexHome(_ explicitCodexHome: String?) -> String {
        let rawValue: String
        if let explicitCodexHome, !explicitCodexHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawValue = explicitCodexHome
        } else {
            rawValue = defaultCodexHome()
        }

        return URL(fileURLWithPath: (rawValue as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    static func status(for codexHome: String?) throws -> StatusSnapshot {
        let normalized = normalizeCodexHome(codexHome)
        try ensureCodexHome(normalized)

        let configText = try readConfigText(at: configPath(in: normalized))
        let currentProvider = readCurrentProvider(from: configText)
        let configuredProviders = listConfiguredProviders(in: configText)
        let rolloutInfo = try collectSessionChanges(codexHome: normalized, targetProvider: nil)
        let sqliteCounts = try readSqliteProviderCounts(codexHome: normalized)
        let backupSummary = try getBackupSummary(codexHome: normalized)

        return StatusSnapshot(
            codexHome: normalized,
            currentProvider: currentProvider,
            configuredProviders: configuredProviders,
            rolloutCounts: rolloutInfo.providerCounts,
            sqliteCounts: sqliteCounts,
            backupRoot: backupsRoot(for: normalized),
            backupSummary: backupSummary
        )
    }

    static func buildProviderOptions(
        status: StatusSnapshot,
        savedProviders: [String],
        manualProviders: [String]
    ) -> [ProviderOption] {
        var sources: [String: Set<ProviderSource>] = [:]

        func addSources(_ providerIDs: [String], source: ProviderSource) {
            for providerID in providerIDs.map(normalizeProviderID).filter({ !$0.isEmpty }) {
                var bucket = sources[providerID] ?? []
                bucket.insert(source)
                sources[providerID] = bucket
            }
        }

        addSources(status.configuredProviders, source: .config)
        addSources(Array(status.rolloutCounts.sessions.keys), source: .rollout)
        addSources(Array(status.rolloutCounts.archivedSessions.keys), source: .rollout)
        if let sqliteCounts = status.sqliteCounts {
            addSources(Array(sqliteCounts.sessions.keys), source: .sqlite)
            addSources(Array(sqliteCounts.archivedSessions.keys), source: .sqlite)
        }
        addSources(savedProviders, source: .manual)
        addSources(manualProviders, source: .manual)
        addSources([status.currentProvider.provider], source: .config)

        let manualSet = Set(manualProviders.map(normalizeProviderID))
        let savedSet = Set(savedProviders.map(normalizeProviderID))

        return sources
            .map { key, value in
                ProviderOption(
                    id: key,
                    sources: value.sorted { $0.rawValue < $1.rawValue },
                    isCurrentProvider: key == status.currentProvider.provider,
                    isManual: manualSet.contains(key),
                    isSaved: savedSet.contains(key)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrentProvider != rhs.isCurrentProvider {
                    return lhs.isCurrentProvider && !rhs.isCurrentProvider
                }
                return lhs.id < rhs.id
            }
    }

    static func runSync(
        codexHome: String?,
        provider: String?,
        keepCount: Int = defaultBackupRetentionCount
    ) throws -> SyncResult {
        let normalized = normalizeCodexHome(codexHome)
        try ensureCodexHome(normalized)

        let configText = try readConfigText(at: configPath(in: normalized))
        let currentProvider = readCurrentProvider(from: configText)
        let targetProvider = normalizeProviderID(provider ?? currentProvider.provider)
        guard !targetProvider.isEmpty else {
            throw messageError("Missing target provider.")
        }

        return try performSync(
            codexHome: normalized,
            targetProvider: targetProvider,
            keepCount: keepCount,
            configBackupText: nil,
            previousProvider: currentProvider.provider
        )
    }

    static func runSwitch(
        codexHome: String?,
        provider: String,
        keepCount: Int = defaultBackupRetentionCount
    ) throws -> SyncResult {
        let normalized = normalizeCodexHome(codexHome)
        try ensureCodexHome(normalized)

        let configLocation = configPath(in: normalized)
        let originalConfigText = try readConfigText(at: configLocation)
        let currentProvider = readCurrentProvider(from: originalConfigText)
        let targetProvider = normalizeProviderID(provider)

        guard !targetProvider.isEmpty else {
            throw messageError("Missing provider id.")
        }

        let configuredProviders = listConfiguredProviders(in: originalConfigText)
        guard configuredProviders.contains(targetProvider) else {
            let joined = configuredProviders.joined(separator: ", ")
            throw messageError("Provider \"\(targetProvider)\" is not declared in config.toml. Available providers: \(joined)")
        }

        let nextConfigText = setRootProvider(in: originalConfigText, to: targetProvider)
        try nextConfigText.write(to: URL(fileURLWithPath: configLocation), atomically: true, encoding: .utf8)

        do {
            var result = try performSync(
                codexHome: normalized,
                targetProvider: targetProvider,
                keepCount: keepCount,
                configBackupText: originalConfigText,
                previousProvider: currentProvider.provider
            )
            result.configUpdated = true
            return result
        } catch {
            try? originalConfigText.write(to: URL(fileURLWithPath: configLocation), atomically: true, encoding: .utf8)
            throw error
        }
    }

    static func restoreBackup(codexHome: String?, backupDir: String) throws -> RestoreResult {
        let normalizedHome = normalizeCodexHome(codexHome)
        try ensureCodexHome(normalizedHome)

        let normalizedBackupDir = URL(fileURLWithPath: (backupDir as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path

        let lock = try acquireLock(codexHome: normalizedHome, label: "restore")
        defer { lock.release() }

        let metadataPath = URL(fileURLWithPath: normalizedBackupDir)
            .appendingPathComponent("metadata.json")
            .path
        let sessionManifestPath = URL(fileURLWithPath: normalizedBackupDir)
            .appendingPathComponent("session-meta-backup.json")
            .path

        let metadata = try decodeJSON(BackupMetadataFile.self, from: metadataPath)
        guard metadata.codexHome == normalizedHome else {
            throw messageError("Backup was created for \(metadata.codexHome), not \(normalizedHome).")
        }

        let manifest = try decodeJSON(SessionBackupManifest.self, from: sessionManifestPath)
        try assertSessionFilesWritable(manifest.files.map(\.path))
        _ = try assertSqliteWritable(codexHome: normalizedHome, busyTimeoutMs: 5_000)

        _ = try copyIfPresent(
            from: URL(fileURLWithPath: normalizedBackupDir).appendingPathComponent("config.toml").path,
            to: configPath(in: normalizedHome),
            overwrite: true
        )

        let backedUpFiles = Set(metadata.dbFiles)
        let backupDBDirectory = URL(fileURLWithPath: normalizedBackupDir).appendingPathComponent("db").path
        for suffix in ["", "-shm", "-wal"] {
            let fileName = "\(stateDatabaseBasename)\(suffix)"
            let destination = URL(fileURLWithPath: normalizedHome).appendingPathComponent(fileName).path
            if !backedUpFiles.contains(fileName),
               FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
        }

        for fileName in metadata.dbFiles {
            _ = try copyIfPresent(
                from: URL(fileURLWithPath: backupDBDirectory).appendingPathComponent(fileName).path,
                to: URL(fileURLWithPath: normalizedHome).appendingPathComponent(fileName).path,
                overwrite: true
            )
        }

        try restoreSessionChanges(from: manifest.files)

        return RestoreResult(
            codexHome: normalizedHome,
            backupDir: normalizedBackupDir,
            targetProvider: metadata.targetProvider,
            createdAt: metadata.createdAt,
            changedSessionFiles: metadata.changedSessionFiles
        )
    }

    static func pruneBackups(
        codexHome: String?,
        keepCount: Int = defaultBackupRetentionCount
    ) throws -> BackupPruneResult {
        guard keepCount >= 1 else {
            throw messageError("keepCount must be 1 or greater.")
        }

        let normalized = normalizeCodexHome(codexHome)
        try ensureCodexHome(normalized)

        let lock = try acquireLock(codexHome: normalized, label: "prune-backups")
        defer { lock.release() }

        return try pruneManagedBackups(codexHome: normalized, keepCount: keepCount)
    }

    static func listBackups(codexHome: String?) throws -> [BackupEntry] {
        let normalized = normalizeCodexHome(codexHome)
        let backupRoot = backupsRoot(for: normalized)
        let directories = try managedBackupDirectories(at: backupRoot)

        return directories.compactMap { directory in
            let metadataPath = directory.appendingPathComponent("metadata.json").path
            let metadata = try? decodeJSON(BackupMetadataFile.self, from: metadataPath)
            guard let metadata else {
                return nil
            }

            return BackupEntry(
                path: directory.path,
                targetProvider: metadata.targetProvider,
                createdAt: metadata.createdAt,
                changedSessionFiles: metadata.changedSessionFiles,
                totalBytes: directorySize(at: directory.path)
            )
        }
    }

    private static func performSync(
        codexHome: String,
        targetProvider: String,
        keepCount: Int,
        configBackupText: String?,
        previousProvider: String
    ) throws -> SyncResult {
        guard keepCount >= 1 else {
            throw messageError("keepCount must be 1 or greater.")
        }

        let startedAt = Date()
        let lock = try acquireLock(codexHome: codexHome, label: "sync")
        defer { lock.release() }

        let sessionInfo = try collectSessionChanges(codexHome: codexHome, targetProvider: targetProvider)
        let split = splitLockedSessionChanges(sessionInfo.changes)
        var skippedRolloutFiles = sessionInfo.lockedPaths + split.locked.map(\.path)
        let configLocation = configPath(in: codexHome)
        _ = try assertSqliteWritable(codexHome: codexHome, busyTimeoutMs: 5_000)
        let backupDir = try createBackup(
            codexHome: codexHome,
            targetProvider: targetProvider,
            sessionChanges: split.writable,
            configPath: configLocation,
            configBackupText: configBackupText
        )

        var appliedSessionChanges: [SessionChange] = []
        do {
            var applyResult: SessionApplyResult?
            let sqliteUpdate = try updateSqliteProvider(
                codexHome: codexHome,
                targetProvider: targetProvider,
                busyTimeoutMs: 5_000
            ) {
                guard !split.writable.isEmpty else {
                    return nil
                }

                let result = try applySessionChanges(split.writable, appliedSessionChanges: &appliedSessionChanges)
                if !appliedSessionChanges.isEmpty {
                    try updateSessionBackupManifest(backupDir: backupDir, sessionChanges: appliedSessionChanges)
                }
                applyResult = result
                return result
            }

            skippedRolloutFiles.append(contentsOf: applyResult?.skippedPaths ?? [])
            skippedRolloutFiles = Array(Set(skippedRolloutFiles)).sorted()

            var autoPruneResult: BackupPruneResult?
            var autoPruneWarning: String?
            do {
                autoPruneResult = try pruneManagedBackups(codexHome: codexHome, keepCount: keepCount)
            } catch {
                autoPruneWarning = "Automatic backup cleanup failed: \(error.localizedDescription)"
            }

            return SyncResult(
                codexHome: codexHome,
                targetProvider: targetProvider,
                previousProvider: previousProvider,
                backupDir: backupDir,
                changedSessionFiles: applyResult?.appliedCount ?? 0,
                skippedLockedRolloutFiles: skippedRolloutFiles,
                sqliteRowsUpdated: sqliteUpdate.updatedRows,
                sqlitePresent: sqliteUpdate.databasePresent,
                rolloutCountsBefore: sessionInfo.providerCounts,
                configUpdated: false,
                autoPruneResult: autoPruneResult,
                autoPruneWarning: autoPruneWarning,
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch {
            if !appliedSessionChanges.isEmpty {
                try? restoreSessionChanges(from: appliedSessionChanges.map {
                    SessionBackupManifestEntry(
                        path: $0.path,
                        originalFirstLine: $0.originalFirstLine,
                        originalSeparator: $0.originalSeparator
                    )
                })
            }

            throw error
        }
    }

    private static func ensureCodexHome(_ codexHome: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexHome, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw messageError("Codex Home was not found: \(codexHome)")
        }
    }

    private static func configPath(in codexHome: String) -> String {
        URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml").path
    }

    private static func readConfigText(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw messageError("config.toml was not found at \(path)")
        }
        return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    private static func readCurrentProvider(from configText: String) -> CurrentProviderInfo {
        for line in splitLines(configText) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[") {
                break
            }

            if let range = trimmed.range(of: #"^model_provider\s*=\s*"([^"]+)""#, options: .regularExpression),
               let providerRange = trimmed[range].range(of: #""([^"]+)""#, options: .regularExpression) {
                let raw = String(trimmed[providerRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return CurrentProviderInfo(provider: raw, implicit: false)
            }
        }

        return CurrentProviderInfo(provider: defaultProvider, implicit: true)
    }

    private static func listConfiguredProviders(in configText: String) -> [String] {
        let pattern = #"^\[model_providers\.([A-Za-z0-9_.-]+)]\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])

        var providers = Set([defaultProvider])
        let nsRange = NSRange(configText.startIndex..<configText.endIndex, in: configText)
        regex?.enumerateMatches(in: configText, options: [], range: nsRange) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: configText) else {
                return
            }
            providers.insert(String(configText[range]))
        }

        return providers.sorted()
    }

    private static func setRootProvider(in configText: String, to provider: String) -> String {
        let newline = configText.contains("\r\n") ? "\r\n" : "\n"
        var lines = splitLines(configText)
        var insertIndex = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                insertIndex = index + 1
                continue
            }

            if trimmed.hasPrefix("[") {
                insertIndex = index
                break
            }

            if trimmed.hasPrefix("model_provider") {
                lines[index] = #"model_provider = "\#(escapeTomlString(provider))""#
                let joined = lines.joined(separator: newline)
                return configText.hasSuffix(newline) ? joined + newline : joined
            }

            insertIndex = index + 1
        }

        lines.insert(#"model_provider = "\#(escapeTomlString(provider))""#, at: insertIndex)
        let joined = lines.joined(separator: newline)
        return configText.hasSuffix(newline) ? joined + newline : joined
    }

    private static func collectSessionChanges(
        codexHome: String,
        targetProvider: String?
    ) throws -> SessionChangeCollection {
        var changes: [SessionChange] = []
        var sessionCounts: [String: Int] = [:]
        var archivedCounts: [String: Int] = [:]

        for directory in SessionDirectory.allCases {
            let rootURL = URL(fileURLWithPath: codexHome).appendingPathComponent(directory.rawValue)
            guard FileManager.default.fileExists(atPath: rootURL.path) else {
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension == "jsonl" else {
                    continue
                }

                let record = try readFirstLineRecord(at: fileURL.path)
                guard let parsed = parseSessionMeta(from: record.firstLine) else {
                    continue
                }

                let currentProvider = normalizeProviderID(parsed.provider.isEmpty ? "(missing)" : parsed.provider)
                switch directory {
                case .sessions:
                    sessionCounts[currentProvider, default: 0] += 1
                case .archivedSessions:
                    archivedCounts[currentProvider, default: 0] += 1
                }

                guard let targetProvider,
                      currentProvider != targetProvider,
                      let updatedFirstLine = updateProvider(in: record.firstLine, targetProvider: targetProvider) else {
                    continue
                }

                let fileLength = try fileSize(at: fileURL.path)
                changes.append(
                    SessionChange(
                        path: fileURL.path,
                        threadID: parsed.threadID,
                        directory: directory,
                        originalFirstLine: record.firstLine,
                        originalSeparator: record.separator,
                        originalOffset: record.offset,
                        originalFileLength: fileLength,
                        updatedFirstLine: updatedFirstLine
                    )
                )
            }
        }

        return SessionChangeCollection(
            changes: changes,
            lockedPaths: [],
            providerCounts: ProviderCounts(sessions: sessionCounts, archivedSessions: archivedCounts)
        )
    }

    private static func splitLockedSessionChanges(_ changes: [SessionChange]) -> (writable: [SessionChange], locked: [SessionChange]) {
        var writable: [SessionChange] = []
        var locked: [SessionChange] = []

        for change in changes {
            do {
                let fd = try openExclusiveFileDescriptor(for: change.path)
                close(fd)
                writable.append(change)
            } catch let error as NSError where error.domain == "ProviderSyncEngine.RolloutBusy" {
                locked.append(change)
            } catch {
                writable.append(change)
            }
        }

        return (writable, locked)
    }

    private static func assertSessionFilesWritable(_ filePaths: [String]) throws {
        let lockedPaths = filePaths.compactMap { path -> String? in
            do {
                let fd = try openExclusiveFileDescriptor(for: path)
                close(fd)
                return nil
            } catch let error as NSError where error.domain == "ProviderSyncEngine.RolloutBusy" {
                return path
            } catch {
                return path
            }
        }

        if !lockedPaths.isEmpty {
            throw messageError(
                "Unable to rewrite rollout files because \(lockedPaths.count) file(s) are currently in use. Close Codex / Codex App / app-server and try again."
            )
        }
    }

    private static func applySessionChanges(
        _ changes: [SessionChange],
        appliedSessionChanges: inout [SessionChange]
    ) throws -> SessionApplyResult {
        var appliedPaths: [String] = []
        var skippedPaths: [String] = []

        for change in changes {
            let applied = try rewriteSessionChange(change)
            if applied {
                appliedPaths.append(change.path)
                appliedSessionChanges.append(change)
            } else {
                skippedPaths.append(change.path)
            }
        }

        return SessionApplyResult(
            appliedCount: appliedPaths.count,
            appliedPaths: appliedPaths.sorted(),
            skippedPaths: skippedPaths.sorted()
        )
    }

    private static func rewriteSessionChange(_ change: SessionChange) throws -> Bool {
        let fd: Int32
        do {
            fd = try openExclusiveFileDescriptor(for: change.path)
        } catch let error as NSError where error.domain == "ProviderSyncEngine.RolloutBusy" {
            return false
        }
        defer { close(fd) }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()

        if Int64(data.count) != change.originalFileLength {
            return false
        }

        let record = parseFirstLineRecord(from: data)
        guard record.firstLine == change.originalFirstLine,
              record.offset == change.originalOffset else {
            return false
        }

        var updatedData = Data(change.updatedFirstLine.utf8)
        if !change.originalSeparator.isEmpty {
            updatedData.append(Data(change.originalSeparator.utf8))
        }
        if record.offset < data.count {
            updatedData.append(data.subdata(in: record.offset..<data.count))
        }

        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: updatedData)
        try handle.synchronize()
        return true
    }

    private static func restoreSessionChanges(from entries: [SessionBackupManifestEntry]) throws {
        for entry in entries {
            do {
                let fd = try openExclusiveFileDescriptor(for: entry.path)
                defer { close(fd) }

                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                try handle.seek(toOffset: 0)
                let data = try handle.readToEnd() ?? Data()
                let current = parseFirstLineRecord(from: data)

                var restored = Data(entry.originalFirstLine.utf8)
                if !entry.originalSeparator.isEmpty {
                    restored.append(Data(entry.originalSeparator.utf8))
                }
                if current.offset < data.count {
                    restored.append(data.subdata(in: current.offset..<data.count))
                }

                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: restored)
                try handle.synchronize()
            }
        }
    }

    private static func readFirstLineRecord(at path: String) throws -> FirstLineRecord {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return parseFirstLineRecord(from: data)
    }

    private static func parseFirstLineRecord(from data: Data) -> FirstLineRecord {
        if let newlineIndex = data.firstIndex(of: 0x0A) {
            let hasCarriageReturn = newlineIndex > 0 && data[data.index(before: newlineIndex)] == 0x0D
            let lineEnd = hasCarriageReturn ? data.index(before: newlineIndex) : newlineIndex
            let firstLine = String(decoding: data[..<lineEnd], as: UTF8.self)
            return FirstLineRecord(
                firstLine: firstLine,
                separator: hasCarriageReturn ? "\r\n" : "\n",
                offset: data.distance(from: data.startIndex, to: data.index(after: newlineIndex))
            )
        }

        return FirstLineRecord(
            firstLine: String(decoding: data, as: UTF8.self),
            separator: "",
            offset: data.count
        )
    }

    private static func parseSessionMeta(from firstLine: String) -> (provider: String, threadID: String?)? {
        guard let data = firstLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              type == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }

        let provider = payload["model_provider"] as? String ?? "(missing)"
        let threadID = payload["id"] as? String
        return (provider, threadID)
    }

    private static func updateProvider(in firstLine: String, targetProvider: String) -> String? {
        let pattern = #""model_provider"\s*:\s*"([^"\\]|\\.)*""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        let replacement = #""model_provider":"\#(escapeJSONString(targetProvider))""#

        if let match = regex?.firstMatch(in: firstLine, range: range) {
            return regex?.stringByReplacingMatches(in: firstLine, options: [], range: match.range, withTemplate: replacement)
        }

        guard let data = firstLine.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var payload = object["payload"] as? [String: Any] else {
            return nil
        }

        payload["model_provider"] = targetProvider
        object["payload"] = payload
        guard let updatedData = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return nil
        }
        return String(data: updatedData, encoding: .utf8)
    }

    private static func readSqliteProviderCounts(codexHome: String) throws -> ProviderCounts? {
        let dbPath = URL(fileURLWithPath: codexHome).appendingPathComponent(stateDatabaseBasename).path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return nil
        }

        let db = try openSQLite(at: dbPath, readonly: true)
        defer { sqlite3_close(db) }

        let sql = """
            SELECT
              CASE
                WHEN model_provider IS NULL OR model_provider = '' THEN '(missing)'
                ELSE model_provider
              END AS model_provider,
              archived,
              COUNT(*) AS count
            FROM threads
            GROUP BY model_provider, archived
            ORDER BY archived, model_provider
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(from: db, action: "read provider counts")
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [String: Int] = [:]
        var archivedSessions: [String: Int] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let provider = sqliteText(statement, column: 0)
            let archived = sqlite3_column_int64(statement, 1) != 0
            let count = Int(sqlite3_column_int(statement, 2))
            if archived {
                archivedSessions[provider] = count
            } else {
                sessions[provider] = count
            }
        }

        return ProviderCounts(sessions: sessions, archivedSessions: archivedSessions)
    }

    private static func assertSqliteWritable(codexHome: String, busyTimeoutMs: Int32) throws -> Bool {
        let dbPath = URL(fileURLWithPath: codexHome).appendingPathComponent(stateDatabaseBasename).path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return false
        }

        let db = try openSQLite(at: dbPath, readonly: false)
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, busyTimeoutMs)
        do {
            try execSQLite("BEGIN IMMEDIATE", db: db)
            try execSQLite("ROLLBACK", db: db)
            return true
        } catch {
            throw sqliteBusyError(action: "update session provider metadata", underlying: error)
        }
    }

    private static func updateSqliteProvider(
        codexHome: String,
        targetProvider: String,
        busyTimeoutMs: Int32,
        applyChanges: () throws -> SessionApplyResult?
    ) throws -> (updatedRows: Int, databasePresent: Bool) {
        let dbPath = URL(fileURLWithPath: codexHome).appendingPathComponent(stateDatabaseBasename).path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            _ = try applyChanges()
            return (0, false)
        }

        let db = try openSQLite(at: dbPath, readonly: false)
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, busyTimeoutMs)
        var transactionOpen = false

        do {
            try execSQLite("BEGIN IMMEDIATE", db: db)
            transactionOpen = true

            let sql = """
                UPDATE threads
                SET model_provider = ?
                WHERE COALESCE(model_provider, '') <> ?
                """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(from: db, action: "prepare SQLite update")
            }
            defer { sqlite3_finalize(statement) }

            bindSQLiteText(targetProvider, to: statement, index: 1)
            bindSQLiteText(targetProvider, to: statement, index: 2)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(from: db, action: "update SQLite threads")
            }

            _ = try applyChanges()
            let updatedRows = Int(sqlite3_changes(db))
            try execSQLite("COMMIT", db: db)
            transactionOpen = false
            return (updatedRows, true)
        } catch {
            if transactionOpen {
                try? execSQLite("ROLLBACK", db: db)
            }
            throw sqliteBusyError(action: "update session provider metadata", underlying: error)
        }
    }

    private static func createBackup(
        codexHome: String,
        targetProvider: String,
        sessionChanges: [SessionChange],
        configPath: String,
        configBackupText: String?
    ) throws -> String {
        let backupRoot = backupsRoot(for: codexHome)
        let timestamp = backupTimestampFormatter.string(from: Date())
        let backupDir = URL(fileURLWithPath: backupRoot).appendingPathComponent(timestamp)
        let dbDirectory = backupDir.appendingPathComponent("db")

        try FileManager.default.createDirectory(
            at: dbDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var copiedDBFiles: [String] = []
        for suffix in ["", "-shm", "-wal"] {
            let fileName = "\(stateDatabaseBasename)\(suffix)"
            let source = URL(fileURLWithPath: codexHome).appendingPathComponent(fileName).path
            let destination = dbDirectory.appendingPathComponent(fileName).path
            if try copyIfPresent(from: source, to: destination, overwrite: false) {
                copiedDBFiles.append(fileName)
            }
        }

        let configBackupLocation = backupDir.appendingPathComponent("config.toml").path
        if let configBackupText {
            try configBackupText.write(to: URL(fileURLWithPath: configBackupLocation), atomically: true, encoding: .utf8)
        } else {
            _ = try copyIfPresent(from: configPath, to: configBackupLocation, overwrite: false)
        }

        let createdAt = Date()
        let manifest = SessionBackupManifest(
            version: 1,
            namespace: backupNamespace,
            codexHome: codexHome,
            targetProvider: targetProvider,
            createdAt: createdAt,
            files: sessionChanges.map {
                SessionBackupManifestEntry(
                    path: $0.path,
                    originalFirstLine: $0.originalFirstLine,
                    originalSeparator: $0.originalSeparator
                )
            }
        )
        try encodeJSON(manifest, to: backupDir.appendingPathComponent("session-meta-backup.json").path)

        let metadata = BackupMetadataFile(
            version: 1,
            namespace: backupNamespace,
            codexHome: codexHome,
            targetProvider: targetProvider,
            createdAt: createdAt,
            dbFiles: copiedDBFiles,
            changedSessionFiles: sessionChanges.count
        )
        try encodeJSON(metadata, to: backupDir.appendingPathComponent("metadata.json").path)

        return backupDir.path
    }

    private static func updateSessionBackupManifest(
        backupDir: String,
        sessionChanges: [SessionChange]
    ) throws {
        let manifestPath = URL(fileURLWithPath: backupDir).appendingPathComponent("session-meta-backup.json").path
        let metadataPath = URL(fileURLWithPath: backupDir).appendingPathComponent("metadata.json").path

        let existingManifest = try decodeJSON(SessionBackupManifest.self, from: manifestPath)
        let existingMetadata = try decodeJSON(BackupMetadataFile.self, from: metadataPath)

        let nextManifest = SessionBackupManifest(
            version: existingManifest.version,
            namespace: existingManifest.namespace,
            codexHome: existingManifest.codexHome,
            targetProvider: existingManifest.targetProvider,
            createdAt: existingManifest.createdAt,
            files: sessionChanges.map {
                SessionBackupManifestEntry(
                    path: $0.path,
                    originalFirstLine: $0.originalFirstLine,
                    originalSeparator: $0.originalSeparator
                )
            }
        )
        let nextMetadata = BackupMetadataFile(
            version: existingMetadata.version,
            namespace: existingMetadata.namespace,
            codexHome: existingMetadata.codexHome,
            targetProvider: existingMetadata.targetProvider,
            createdAt: existingMetadata.createdAt,
            dbFiles: existingMetadata.dbFiles,
            changedSessionFiles: sessionChanges.count
        )

        try encodeJSON(nextManifest, to: manifestPath)
        try encodeJSON(nextMetadata, to: metadataPath)
    }

    private static func getBackupSummary(codexHome: String) throws -> BackupSummary {
        let backupRoot = backupsRoot(for: codexHome)
        guard FileManager.default.fileExists(atPath: backupRoot) else {
            return .empty
        }

        let directories = try managedBackupDirectories(at: backupRoot)
        let totalBytes = directories.reduce(Int64.zero) { partialResult, directory in
            partialResult + directorySize(at: directory.path)
        }

        return BackupSummary(count: directories.count, totalBytes: totalBytes)
    }

    private static func pruneManagedBackups(codexHome: String, keepCount: Int) throws -> BackupPruneResult {
        let backupRoot = backupsRoot(for: codexHome)
        guard FileManager.default.fileExists(atPath: backupRoot) else {
            return BackupPruneResult(backupRoot: backupRoot, deletedCount: 0, remainingCount: 0, freedBytes: 0)
        }

        let directories = try managedBackupDirectories(at: backupRoot)
        let toDelete = Array(directories.dropFirst(keepCount))
        let freedBytes = toDelete.reduce(Int64.zero) { partialResult, directory in
            partialResult + directorySize(at: directory.path)
        }

        for directory in toDelete {
            try FileManager.default.removeItem(at: directory)
        }

        return BackupPruneResult(
            backupRoot: backupRoot,
            deletedCount: toDelete.count,
            remainingCount: directories.count - toDelete.count,
            freedBytes: freedBytes
        )
    }

    private static func managedBackupDirectories(at backupRoot: String) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupRoot) else {
            return []
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: backupRoot),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { url in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }

                let metadataPath = url.appendingPathComponent("metadata.json").path
                guard let metadata = try? decodeJSON(BackupMetadataFile.self, from: metadataPath) else {
                    return false
                }
                return metadata.namespace == backupNamespace
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func acquireLock(codexHome: String, label: String) throws -> LockHandle {
        let tmpDirectory = URL(fileURLWithPath: codexHome).appendingPathComponent("tmp")
        try FileManager.default.createDirectory(
            at: tmpDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let lockURL = tmpDirectory.appendingPathComponent(lockDirectoryName)
        do {
            try FileManager.default.createDirectory(
                at: lockURL,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            throw messageError(
                "Lock already exists at \(lockURL.path). Close Codex / Codex App / app-server and retry, or remove the stale lock if no sync is running."
            )
        }

        do {
            let owner: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "startedAt": lockOwnerTimestamp(),
                "label": label,
                "cwd": FileManager.default.currentDirectoryPath
            ]
            let data = try JSONSerialization.data(withJSONObject: owner, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: lockURL.appendingPathComponent("owner.json"))
            return LockHandle(path: lockURL.path)
        } catch {
            try? FileManager.default.removeItem(at: lockURL)
            throw error
        }
    }

    private static func openExclusiveFileDescriptor(for path: String) throws -> Int32 {
        let fd = path.withCString { open($0, O_RDWR | O_EXLOCK | O_NONBLOCK) }
        guard fd != -1 else {
            if errno == EWOULDBLOCK || errno == EAGAIN || errno == EBUSY {
                throw NSError(
                    domain: "ProviderSyncEngine.RolloutBusy",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "Rollout file is currently busy: \(path)"]
                )
            }

            let posix = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(posix)
        }
        return fd
    }

    private static func openSQLite(at path: String, readonly: Bool) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = readonly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let error = sqliteError(from: database, action: readonly ? "open SQLite database" : "open SQLite database for writing")
            sqlite3_close(database)
            throw error
        }
        return database
    }

    private static func execSQLite(_ sql: String, db: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }
        guard rc == SQLITE_OK else {
            throw sqliteError(from: db, action: sql)
        }
    }

    private static func bindSQLiteText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransientDestructor)
        }
    }

    private static func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: value)
    }

    private static func sqliteError(from db: OpaquePointer?, action: String) -> Error {
        let code = Int(sqlite3_errcode(db))
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error."

        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return messageError(
                "Unable to \(action) because state_5.sqlite is currently in use. Close Codex / Codex App / app-server and retry. Original error: \(message)"
            )
        }

        return messageError("SQLite failed to \(action): \(message)")
    }

    private static func sqliteBusyError(action: String, underlying: Error) -> Error {
        if let error = underlying as NSError?,
           error.localizedDescription.contains("state_5.sqlite is currently in use") {
            return error
        }

        return messageError(
            "Unable to \(action) because state_5.sqlite is currently in use or rejected the transaction. \(underlying.localizedDescription)"
        )
    }

    private static func copyIfPresent(from source: String, to destination: String, overwrite: Bool) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source) else {
            return false
        }

        let destinationURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        if overwrite, FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.removeItem(atPath: destination)
        }
        if !FileManager.default.fileExists(atPath: destination) {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
        }
        return true
    }

    private static func directorySize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return 0
        }

        var total: Int64 = 0
        for case let file as String in enumerator {
            let fullPath = URL(fileURLWithPath: path).appendingPathComponent(file).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let fileSize = attributes[.size] as? NSNumber else {
                continue
            }
            total += fileSize.int64Value
        }
        return total
    }

    private static func fileSize(at path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func encodeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decoder.decode(T.self, from: data)
    }

    private static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func normalizeProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeJSONString(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                result.append(Character(scalar))
            }
        }
        return result
    }

    private static func escapeTomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func messageError(_ message: String) -> NSError {
        NSError(domain: "ProviderSyncEngine", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()

    private static func lockOwnerTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
