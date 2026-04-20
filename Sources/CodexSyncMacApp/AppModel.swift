import AppKit
import Foundation

private struct PersistedAppSettings: Codable {
    var recentCodexHomes: [String] = []
    var savedProviders: [String] = []
    var manualProviders: [String] = []
    var lastCodexHome: String?
    var lastSelectedProvider: String?
    var lastBackupDirectory: String?
    var backupRetentionCount: Int = ProviderSyncEngine.defaultBackupRetentionCount

    mutating func normalize() {
        recentCodexHomes = normalizedList(recentCodexHomes, mapPath: true).prefix(10).map { $0 }
        savedProviders = normalizedList(savedProviders)
        manualProviders = normalizedList(manualProviders)
        if let lastCodexHome {
            self.lastCodexHome = normalizePath(lastCodexHome)
        }
        if let lastSelectedProvider {
            self.lastSelectedProvider = normalizeValue(lastSelectedProvider)
        }
        if let lastBackupDirectory {
            self.lastBackupDirectory = normalizePath(lastBackupDirectory)
        }
        backupRetentionCount = max(1, backupRetentionCount)
    }

    mutating func recordCodexHome(_ codexHome: String) {
        let normalized = normalizePath(codexHome)
        var homes = [normalized]
        homes.append(contentsOf: recentCodexHomes)
        recentCodexHomes = normalizedList(homes, mapPath: true).prefix(10).map { $0 }
        lastCodexHome = normalized
    }

    mutating func mergeDetectedProviders(_ providerIDs: [String]) {
        savedProviders = normalizedList(savedProviders + providerIDs)
    }

    mutating func addManualProvider(_ providerID: String) {
        let normalized = normalizeValue(providerID)
        guard !normalized.isEmpty else { return }
        savedProviders = normalizedList(savedProviders + [normalized])
        manualProviders = normalizedList(manualProviders + [normalized])
        lastSelectedProvider = normalized
    }

    mutating func removeManualProvider(_ providerID: String) {
        let normalized = normalizeValue(providerID)
        savedProviders.removeAll { $0 == normalized }
        manualProviders.removeAll { $0 == normalized }
        if lastSelectedProvider == normalized {
            lastSelectedProvider = nil
        }
    }

    mutating func updateSelection(providerID: String?, backupDirectory: String?, retentionCount: Int? = nil) {
        if let providerID, !providerID.isEmpty {
            lastSelectedProvider = normalizeValue(providerID)
        }
        if let backupDirectory, !backupDirectory.isEmpty {
            lastBackupDirectory = normalizePath(backupDirectory)
        }
        if let retentionCount {
            backupRetentionCount = max(1, retentionCount)
        }
    }

    private func normalizeValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizePath(_ value: String) -> String {
        URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private func normalizedList(_ values: [String], mapPath: Bool = false) -> [String] {
        let normalized: [String] = values
            .map { value in
                mapPath ? normalizePath(value) : normalizeValue(value)
            }
            .filter { !$0.isEmpty }

        return Array(Set(normalized)).sorted()
    }
}

private struct AppSettingsStore {
    private let fileURL: URL

    init() {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("codex-provider-sync")
        fileURL = baseDirectory.appendingPathComponent("settings.json")
    }

    func load() -> PersistedAppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(PersistedAppSettings.self, from: data) else {
            var fallback = PersistedAppSettings()
            fallback.normalize()
            return fallback
        }

        var normalized = settings
        normalized.normalize()
        return normalized
    }

    func save(_ settings: PersistedAppSettings) {
        var copy = settings
        copy.normalize()

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Failed to save settings: %@", error.localizedDescription)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var codexHomePath: String
    @Published var selectedProviderID: String?
    @Published var selectedBackupPath: String?
    @Published var manualProviderInput = ""
    @Published var updateConfig = false
    @Published var backupRetentionCount: Int
    @Published var statusText = "Ready"
    @Published var logs: [String] = []
    @Published var isRunning = false
    @Published var snapshot: StatusSnapshot?
    @Published var providerOptions: [ProviderOption] = []
    @Published var backupEntries: [BackupEntry] = []
    @Published var lastSyncResult: SyncResult?
    @Published var lastRestoreResult: RestoreResult?

    private let settingsStore = AppSettingsStore()
    private var settings: PersistedAppSettings
    private var hasLoaded = false

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private lazy var fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    init() {
        let loaded = settingsStore.load()
        settings = loaded
        codexHomePath = loaded.lastCodexHome ?? ProviderSyncEngine.defaultCodexHome()
        backupRetentionCount = max(1, loaded.backupRetentionCount)
        selectedProviderID = loaded.lastSelectedProvider
        selectedBackupPath = loaded.lastBackupDirectory
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refreshStatus(clearLogs: false)
    }

    var currentProviderLabel: String {
        snapshot?.currentProvider.provider ?? "unknown"
    }

    var currentProviderFootnote: String {
        guard let snapshot else {
            return "读取 config.toml 后会显示当前 root provider。"
        }

        return snapshot.currentProvider.implicit
            ? "config.toml 没写根级 model_provider，按 openai 推断。"
            : "来自 config.toml 的根级 model_provider。"
    }

    var selectedProviderLabel: String {
        selectedProviderID ?? snapshot?.currentProvider.provider ?? "未选择"
    }

    var selectedBackup: BackupEntry? {
        guard let selectedBackupPath else {
            return backupEntries.first
        }
        return backupEntries.first(where: { $0.path == selectedBackupPath }) ?? backupEntries.first
    }

    var syncHintText: String {
        updateConfig
            ? "会先切换 config.toml 的 root provider，再同步 rollout files 和 SQLite。"
            : "不会改 config.toml，只把历史会话改成选中的 provider。"
    }

    var canExecuteSync: Bool {
        !isRunning && !(selectedProviderID ?? "").isEmpty
    }

    var canRestoreBackup: Bool {
        !isRunning && selectedBackup != nil
    }

    var canPruneBackups: Bool {
        !isRunning
    }

    var backupsRootPath: String {
        snapshot?.backupRoot ?? ProviderSyncEngine.backupsRoot(for: normalizedCodexHome())
    }

    var lastActionSummary: String {
        if let lastSyncResult {
            return "最近一次同步: \(lastSyncResult.targetProvider) · \(lastSyncResult.durationText)"
        }
        if let lastRestoreResult {
            return "最近一次恢复: \(lastRestoreResult.targetProvider)"
        }
        return "还没有执行过同步或恢复。"
    }

    var statusDigest: String {
        guard let snapshot else {
            return """
            点击 Refresh 扫描当前 Codex Home。

            应用会读取:
            - config.toml 的 root provider
            - sessions / archived_sessions 的 rollout files
            - state_5.sqlite 的 threads 表
            - backups_state/provider-sync 里的备份
            """
        }

        return buildStatusDigest(from: snapshot)
    }

    func pickCodexHome() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Home"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let path = panel.url?.path {
            codexHomePath = path
            persistSelections()
        }
    }

    func refreshStatus(clearLogs: Bool = true) {
        let codexHome = normalizedCodexHome()
        settings.recordCodexHome(codexHome)
        settings.updateSelection(
            providerID: selectedProviderID,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)

        if clearLogs {
            logs.removeAll()
        }
        appendLog("Refreshing status for \(codexHome)")
        statusText = "Refreshing"
        isRunning = true

        runBackground(
            work: {
                let snapshot = try ProviderSyncEngine.status(for: codexHome)
                let backups = try ProviderSyncEngine.listBackups(codexHome: codexHome)
                return (snapshot, backups)
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let payload):
                    let (snapshot, backups) = payload
                    self.applySnapshot(snapshot, backups: backups)
                    self.appendLog("Refresh complete. Found \(backups.count) backup(s).")
                    self.statusText = "Ready"
                case .failure(let error):
                    self.statusText = "Refresh failed"
                    self.appendLog("Refresh failed: \(error.localizedDescription)")
                }

                self.isRunning = false
            }
        )
    }

    func runSync() {
        let codexHome = normalizedCodexHome()
        let targetProvider = (selectedProviderID ?? snapshot?.currentProvider.provider ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !targetProvider.isEmpty else {
            appendLog("Please choose a target provider first.")
            statusText = "Missing provider"
            return
        }

        settings.recordCodexHome(codexHome)
        settings.updateSelection(
            providerID: targetProvider,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)

        logs.removeAll()
        appendLog(updateConfig
            ? "Starting switch + sync for provider \(targetProvider)"
            : "Starting sync for provider \(targetProvider)")
        statusText = updateConfig ? "Switching + Syncing" : "Syncing"
        isRunning = true

        let keepCount = max(1, backupRetentionCount)
        let shouldUpdateConfig = updateConfig

        runBackground(
            work: {
                if shouldUpdateConfig {
                    return try ProviderSyncEngine.runSwitch(
                        codexHome: codexHome,
                        provider: targetProvider,
                        keepCount: keepCount
                    )
                }

                return try ProviderSyncEngine.runSync(
                    codexHome: codexHome,
                    provider: targetProvider,
                    keepCount: keepCount
                )
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let syncResult):
                    self.lastSyncResult = syncResult
                    self.appendLog("Backup saved to \(syncResult.backupDir)")
                    self.appendLog("Updated \(syncResult.changedSessionFiles) rollout file(s).")
                    if syncResult.sqlitePresent {
                        self.appendLog("Updated \(syncResult.sqliteRowsUpdated) SQLite row(s).")
                    } else {
                        self.appendLog("state_5.sqlite was not present, so only rollout files were changed.")
                    }
                    if syncResult.configUpdated {
                        self.appendLog("config.toml root provider was updated to \(syncResult.targetProvider).")
                    }
                    if !syncResult.skippedLockedRolloutFiles.isEmpty {
                        self.appendLog("Skipped \(syncResult.skippedLockedRolloutFiles.count) locked rollout file(s):")
                        syncResult.skippedLockedRolloutFiles.forEach { self.appendLog("  \($0)") }
                    }
                    if let pruneResult = syncResult.autoPruneResult {
                        self.appendLog(
                            "Auto-pruned \(pruneResult.deletedCount) old backup(s), \(pruneResult.remainingCount) remain."
                        )
                    }
                    if let warning = syncResult.autoPruneWarning {
                        self.appendLog(warning)
                    }
                    self.appendLog("Sync finished in \(syncResult.durationText).")
                    self.statusText = "Sync complete"
                    self.selectedBackupPath = syncResult.backupDir
                    self.refreshStatus(clearLogs: false)
                case .failure(let error):
                    self.statusText = "Sync failed"
                    self.appendLog("Sync failed: \(error.localizedDescription)")
                    self.isRunning = false
                }
            }
        )
    }

    func restoreSelectedBackup() {
        guard let selectedBackup else {
            appendLog("Choose a backup before restoring.")
            statusText = "Missing backup"
            return
        }

        let codexHome = normalizedCodexHome()
        settings.recordCodexHome(codexHome)
        settings.updateSelection(
            providerID: selectedProviderID,
            backupDirectory: selectedBackup.path,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)

        appendLog("Restoring backup \(selectedBackup.path)")
        statusText = "Restoring"
        isRunning = true

        runBackground(
            work: {
                try ProviderSyncEngine.restoreBackup(
                    codexHome: codexHome,
                    backupDir: selectedBackup.path
                )
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let restoreResult):
                    self.lastRestoreResult = restoreResult
                    self.appendLog(
                        "Restore finished. Provider=\(restoreResult.targetProvider), rollout files=\(restoreResult.changedSessionFiles)."
                    )
                    self.statusText = "Restore complete"
                    self.refreshStatus(clearLogs: false)
                case .failure(let error):
                    self.statusText = "Restore failed"
                    self.appendLog("Restore failed: \(error.localizedDescription)")
                    self.isRunning = false
                }
            }
        )
    }

    func pruneBackups() {
        let codexHome = normalizedCodexHome()
        let keepCount = max(1, backupRetentionCount)

        appendLog("Pruning backups, keeping the newest \(keepCount).")
        statusText = "Pruning"
        isRunning = true

        runBackground(
            work: {
                try ProviderSyncEngine.pruneBackups(codexHome: codexHome, keepCount: keepCount)
            },
            completion: { [weak self] result in
                guard let self else { return }

                switch result {
                case .success(let pruneResult):
                    self.appendLog(
                        "Deleted \(pruneResult.deletedCount) backup(s), freed \(Self.byteCount(pruneResult.freedBytes))."
                    )
                    self.statusText = "Prune complete"
                    self.refreshStatus(clearLogs: false)
                case .failure(let error):
                    self.statusText = "Prune failed"
                    self.appendLog("Prune failed: \(error.localizedDescription)")
                    self.isRunning = false
                }
            }
        )
    }

    func addManualProvider() {
        let providerID = manualProviderInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            appendLog("Manual provider id is empty.")
            return
        }

        settings.addManualProvider(providerID)
        settings.updateSelection(
            providerID: providerID,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)
        manualProviderInput = ""
        selectedProviderID = providerID
        rebuildProviderOptions()
        appendLog("Added manual provider \(providerID).")
    }

    func removeSelectedManualProvider() {
        guard let providerID = selectedProviderID else {
            appendLog("Pick a provider first.")
            return
        }

        guard settings.manualProviders.contains(providerID) else {
            appendLog("Selected provider is not a manual entry.")
            return
        }

        settings.removeManualProvider(providerID)
        settings.updateSelection(
            providerID: nil,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)
        rebuildProviderOptions()
        if !providerOptions.contains(where: { $0.id == providerID }) {
            selectedProviderID = snapshot?.currentProvider.provider
        }
        appendLog("Removed manual provider \(providerID).")
    }

    func selectProvider(_ providerID: String) {
        selectedProviderID = providerID
        persistSelections()
    }

    func selectBackup(_ backupPath: String) {
        selectedBackupPath = backupPath
        persistSelections()
    }

    func clearLogs() {
        logs.removeAll()
        appendLog("Log cleared.")
    }

    func revealCodexHome() {
        reveal(path: normalizedCodexHome())
    }

    func revealBackupsRoot() {
        reveal(path: backupsRootPath)
    }

    func revealSelectedBackup() {
        guard let selectedBackup else {
            appendLog("No backup selected.")
            return
        }
        reveal(path: selectedBackup.path)
    }

    func fillCodexHomeFromRecent(_ path: String) {
        codexHomePath = path
        persistSelections()
    }

    var recentCodexHomes: [String] {
        settings.recentCodexHomes.sorted()
    }

    func providerCountRows(for directory: SessionDirectory, from counts: ProviderCounts?) -> [(String, Int)] {
        counts?.entries(in: directory) ?? []
    }

    func formattedBackupDate(for entry: BackupEntry) -> String {
        fullDateFormatter.string(from: entry.createdAt)
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func applySnapshot(_ snapshot: StatusSnapshot, backups: [BackupEntry]) {
        self.snapshot = snapshot
        backupEntries = backups

        settings.recordCodexHome(snapshot.codexHome)
        var detectedProviders = snapshot.configuredProviders
        detectedProviders.append(contentsOf: Array(snapshot.rolloutCounts.sessions.keys))
        detectedProviders.append(contentsOf: Array(snapshot.rolloutCounts.archivedSessions.keys))
        if let sqliteCounts = snapshot.sqliteCounts {
            detectedProviders.append(contentsOf: Array(sqliteCounts.sessions.keys))
            detectedProviders.append(contentsOf: Array(sqliteCounts.archivedSessions.keys))
        }
        detectedProviders.append(snapshot.currentProvider.provider)
        settings.mergeDetectedProviders(detectedProviders)
        settings.updateSelection(
            providerID: selectedProviderID,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)

        rebuildProviderOptions()

        if let selectedProviderID,
           providerOptions.contains(where: { $0.id == selectedProviderID }) {
            self.selectedProviderID = selectedProviderID
        } else {
            self.selectedProviderID = settings.lastSelectedProvider.flatMap { remembered in
                providerOptions.contains(where: { $0.id == remembered }) ? remembered : nil
            } ?? snapshot.currentProvider.provider
        }

        if let selectedBackupPath,
           backups.contains(where: { $0.path == selectedBackupPath }) {
            self.selectedBackupPath = selectedBackupPath
        } else {
            self.selectedBackupPath = settings.lastBackupDirectory.flatMap { remembered in
                backups.contains(where: { $0.path == remembered }) ? remembered : nil
            } ?? backups.first?.path
        }

        persistSelections()
    }

    private func rebuildProviderOptions() {
        guard let snapshot else {
            providerOptions = []
            return
        }

        providerOptions = ProviderSyncEngine.buildProviderOptions(
            status: snapshot,
            savedProviders: settings.savedProviders,
            manualProviders: settings.manualProviders
        )
    }

    private func persistSelections() {
        settings.recordCodexHome(normalizedCodexHome())
        settings.updateSelection(
            providerID: selectedProviderID,
            backupDirectory: selectedBackupPath,
            retentionCount: backupRetentionCount
        )
        settingsStore.save(settings)
    }

    private func normalizedCodexHome() -> String {
        ProviderSyncEngine.normalizeCodexHome(codexHomePath)
    }

    private func reveal(path: String) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            appendLog("Path does not exist yet: \(normalizedPath)")
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: normalizedPath)
    }

    private func appendLog(_ message: String) {
        logs.append("[\(timeFormatter.string(from: Date()))] \(message)")
    }

    private func buildStatusDigest(from snapshot: StatusSnapshot) -> String {
        [
            "Codex Home",
            "  \(snapshot.codexHome)",
            "",
            "Current Root Provider",
            "  \(snapshot.currentProvider.provider)\(snapshot.currentProvider.implicit ? " (implicit default)" : "")",
            "",
            "Configured Providers",
            "  \(snapshot.configuredProviders.joined(separator: ", "))",
            "",
            "Rollout Files",
            "  sessions: \(formatCounts(snapshot.rolloutCounts.entries(in: .sessions)))",
            "  archived: \(formatCounts(snapshot.rolloutCounts.entries(in: .archivedSessions)))",
            "",
            "SQLite Threads",
            "  sessions: \(formatCounts(snapshot.sqliteCounts?.entries(in: .sessions) ?? []))",
            "  archived: \(formatCounts(snapshot.sqliteCounts?.entries(in: .archivedSessions) ?? []))",
            "",
            "Backups",
            "  \(snapshot.backupSummary.count) item(s), \(Self.byteCount(snapshot.backupSummary.totalBytes))",
            "  root: \(snapshot.backupRoot)"
        ].joined(separator: "\n")
    }

    private func formatCounts(_ rows: [(String, Int)]) -> String {
        if rows.isEmpty {
            return "none"
        }
        return rows.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private func runBackground<T: Sendable>(
        work: @escaping @Sendable () throws -> T,
        completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result(catching: work)
            Task { @MainActor in
                completion(result)
            }
        }
    }
}
