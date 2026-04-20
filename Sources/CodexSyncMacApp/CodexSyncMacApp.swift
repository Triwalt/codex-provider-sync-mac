import SwiftUI

@main
struct CodexProviderSyncMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1260, minHeight: 820)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                workspaceSection
                HStack(alignment: .top, spacing: 20) {
                    mainColumn
                    sidebar
                        .frame(width: 360)
                }
            }
            .padding(24)
        }
        .background(background)
        .task {
            model.loadIfNeeded()
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.95, blue: 0.90),
                    Color(red: 0.90, green: 0.95, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.94, green: 0.72, blue: 0.44).opacity(0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 24)
                .offset(x: 420, y: -240)

            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .frame(width: 520, height: 280)
                .blur(radius: 80)
                .offset(x: -360, y: -180)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Codex Provider Sync")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("把 `~/.codex` 里的 rollout files 和 `state_5.sqlite` 一起对齐到目标 provider，让切换 provider 后的历史会话重新可见。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    HeroBadge(title: "SwiftUI", tint: Color(red: 0.19, green: 0.44, blue: 0.82))
                    HeroBadge(title: "Rollout + SQLite", tint: Color(red: 0.15, green: 0.58, blue: 0.42))
                    HeroBadge(title: "Backup / Restore", tint: Color(red: 0.80, green: 0.48, blue: 0.16))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(model.statusText)
                    .font(.system(size: 14, weight: .semibold))
                Text(model.lastActionSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var workspaceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codex Home")
                            .font(.headline)
                        Text("默认是 `~/.codex`。应用会读取这里的 `config.toml`、`sessions`、`archived_sessions`、`state_5.sqlite` 和 `backups_state/provider-sync`。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.recentCodexHomes.isEmpty {
                        Menu("Recent") {
                            ForEach(model.recentCodexHomes, id: \.self) { path in
                                Button(path) {
                                    model.fillCodexHomeFromRecent(path)
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                HStack(spacing: 10) {
                    TextField("Enter Codex Home", text: $model.codexHomePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        model.pickCodexHome()
                    }
                    .buttonStyle(.bordered)
                    Button("Reveal") {
                        model.revealCodexHome()
                    }
                    .buttonStyle(.bordered)
                    Button("Refresh") {
                        model.refreshStatus()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                }
            }
            .padding(8)
        } label: {
            Label("Workspace", systemImage: "externaldrive.connected.to.line.below")
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            overviewSection
            providerSection
            executionSection
            logSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusSection
            distributionsSection
            backupsSection
        }
    }

    private var overviewSection: some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCard(
                    title: "Current",
                    value: model.currentProviderLabel,
                    caption: model.snapshot?.currentProvider.implicit == true ? "implicit" : "config root"
                )
                MetricCard(
                    title: "Selected",
                    value: model.selectedProviderLabel,
                    caption: model.updateConfig ? "switch + sync" : "sync only"
                )
                MetricCard(
                    title: "Backups",
                    value: "\(model.snapshot?.backupSummary.count ?? 0)",
                    caption: AppModel.byteCount(model.snapshot?.backupSummary.totalBytes ?? 0)
                )
                MetricCard(
                    title: "Providers",
                    value: "\(model.providerOptions.count)",
                    caption: "detected + manual"
                )
            }
            .padding(8)
        } label: {
            Label("Overview", systemImage: "chart.bar.xaxis")
        }
    }

    private var providerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provider Radar")
                            .font(.headline)
                        Text("选择目标 provider。来源会标明它是从 config、rollout、SQLite 还是手动输入里发现的。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.currentProviderFootnote)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.providerOptions) { option in
                            ProviderCard(
                                option: option,
                                isSelected: model.selectedProviderID == option.id
                            ) {
                                model.selectProvider(option.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 240, maxHeight: 340)

                HStack(spacing: 10) {
                    TextField("Manual provider id", text: $model.manualProviderInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        model.addManualProvider()
                    }
                    .buttonStyle(.bordered)
                    Button("Remove Manual") {
                        model.removeSelectedManualProvider()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(8)
        } label: {
            Label("Providers", systemImage: "person.3.sequence")
        }
    }

    private var executionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Execution")
                        .font(.headline)

                    HStack(alignment: .center, spacing: 12) {
                        Toggle("Also update root `model_provider` in config.toml", isOn: $model.updateConfig)
                            .toggleStyle(.checkbox)
                        Spacer()
                        Stepper(value: $model.backupRetentionCount, in: 1...1000) {
                            Text("Keep latest \(model.backupRetentionCount) backup(s)")
                                .font(.system(size: 13))
                        }
                        .frame(maxWidth: 280, alignment: .trailing)
                    }

                    Text(model.syncHintText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if model.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Selected provider: \(model.selectedProviderLabel)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.runSync()
                    } label: {
                        Label(model.updateConfig ? "Switch + Sync" : "Sync History", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExecuteSync)

                    Button {
                        model.restoreSelectedBackup()
                    } label: {
                        Label("Restore Backup", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canRestoreBackup)

                    Button {
                        model.pruneBackups()
                    } label: {
                        Label("Prune Backups", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canPruneBackups)

                    Spacer()

                    Button("Open Backups") {
                        model.revealBackupsRoot()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(8)
        } label: {
            Label("Actions", systemImage: "play.circle")
        }
    }

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Run Log")
                        .font(.headline)
                    Spacer()
                    Button("Clear") {
                        model.clearLogs()
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView {
                    Text(model.logs.isEmpty ? "No logs yet." : model.logs.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        )
                }
                .frame(minHeight: 220, maxHeight: .infinity)
            }
            .padding(8)
        } label: {
            Label("Log", systemImage: "terminal")
        }
    }

    private var statusSection: some View {
        GroupBox {
            ScrollView {
                Text(model.statusDigest)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 240)
        } label: {
            Label("Snapshot", systemImage: "waveform.path.ecg.text")
        }
    }

    private var distributionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                CountSection(
                    title: "Rollout Files",
                    rows: model.providerCountRows(for: .sessions, from: model.snapshot?.rolloutCounts),
                    footer: "sessions"
                )
                CountSection(
                    title: "Archived Rollouts",
                    rows: model.providerCountRows(for: .archivedSessions, from: model.snapshot?.rolloutCounts),
                    footer: "archived_sessions"
                )
                CountSection(
                    title: "SQLite Threads",
                    rows: model.providerCountRows(for: .sessions, from: model.snapshot?.sqliteCounts),
                    footer: "threads.archived = 0"
                )
                CountSection(
                    title: "SQLite Archived",
                    rows: model.providerCountRows(for: .archivedSessions, from: model.snapshot?.sqliteCounts),
                    footer: "threads.archived = 1"
                )
            }
            .padding(8)
        } label: {
            Label("Distributions", systemImage: "square.3.layers.3d.down.forward")
        }
    }

    private var backupsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Backups")
                        .font(.headline)
                    Spacer()
                    Button("Reveal Selected") {
                        model.revealSelectedBackup()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedBackup == nil)
                }

                if model.backupEntries.isEmpty {
                    Text("还没有检测到由本工具创建的备份。同步一次后，这里会出现可恢复的快照。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.backupEntries) { entry in
                                BackupCard(
                                    entry: entry,
                                    isSelected: model.selectedBackupPath == entry.path
                                ) {
                                    model.selectBackup(entry.path)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 360)
                }
            }
            .padding(8)
        } label: {
            Label("Recovery", systemImage: "shippingbox")
        }
    }
}

private struct HeroBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
    }
}

private struct ProviderCard: View {
    let option: ProviderOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(option.id)
                            .font(.system(size: 15, weight: .semibold))
                        if option.isCurrentProvider {
                            SourceChip(label: "Current", tint: .blue)
                        }
                        if option.isManual {
                            SourceChip(label: "Manual", tint: .orange)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(option.sources, id: \.self) { source in
                            SourceChip(label: source.title, tint: color(for: source))
                        }
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.56))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func color(for source: ProviderSource) -> Color {
        switch source {
        case .config:
            return Color(red: 0.16, green: 0.45, blue: 0.84)
        case .rollout:
            return Color(red: 0.16, green: 0.62, blue: 0.36)
        case .sqlite:
            return Color(red: 0.64, green: 0.31, blue: 0.16)
        case .manual:
            return Color(red: 0.76, green: 0.49, blue: 0.14)
        }
    }
}

private struct SourceChip: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct CountSection: View {
    let title: String
    let rows: [(String, Int)]
    let footer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if rows.isEmpty {
                Text("none")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(row.1)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.54))
        )
    }
}

private struct BackupCard: View {
    @EnvironmentObject private var model: AppModel

    let entry: BackupEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.targetProvider)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }

                Text(model.formattedBackupDate(for: entry))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("\(entry.changedSessionFiles) rollout file(s) · \(AppModel.byteCount(entry.totalBytes))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(entry.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.56))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
