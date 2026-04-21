# Codex Provider Sync for Mac

<p align="center">
  <strong>让切换 <code>model_provider</code> 后重新可见的 Codex 历史回到眼前</strong>
  <br />
  <strong>Bring hidden Codex history back after switching <code>model_provider</code></strong>
</p>

<p align="center">
  <a href="https://github.com/Triwalt/codex-provider-sync-mac/actions/workflows/build.yml">
    <img alt="Build" src="https://github.com/Triwalt/codex-provider-sync-mac/actions/workflows/build.yml/badge.svg" />
  </a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-111827?logo=apple&logoColor=white" />
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" />
  <a href="https://github.com/Triwalt/codex-provider-sync-mac/blob/main/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-16a34a.svg" />
  </a>
</p>

<p align="center">
  <a href="#中文说明">中文说明</a>
  ·
  <a href="#english">English</a>
  ·
  <a href="https://github.com/Triwalt/codex-provider-sync-mac/releases/latest">Download Latest Release</a>
</p>

> Principle credit: the synchronization logic behind this app is derived from [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync).  
> 原理来源说明：本项目的同步思路来自 [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)，这里将其重构为原生 macOS 应用与更适合本地桌面使用的交互流程。

---

<a id="中文说明"></a>

## 中文说明

### 项目简介

`Codex Provider Sync for Mac` 是一个原生 SwiftUI macOS 应用，用来修复这样一种常见情况：

- 你在 Codex 里切换了根级 `model_provider`
- 老的历史会话还在本地
- 但因为 provider 标记不一致，这些历史在当前 provider 下不再可见

这个应用会同时处理：

- `~/.codex/config.toml`
- `sessions` 与 `archived_sessions` 中的 `rollout-*.jsonl`
- `state_5.sqlite`

目标是让本地历史在目标 provider 视角下重新对齐、重新可见，同时保留完整备份与可恢复能力。

### 原理来源

本项目不是凭空设计同步算法，而是基于 [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync) 的核心思路继续实现：

- 保留“同时修正 rollout 元数据与 SQLite 元数据”的核心原则
- 将其落地为原生 macOS GUI
- 补充本地桌面场景更需要的备份、恢复、可视化状态摘要与目录操作体验

如果你熟悉 Dailin 版本，可以把这个项目理解为：

> 一个面向 macOS 的原生桌面重实现，而不是另起炉灶发明一套不同原理。

### 适用场景

它适合这些情况：

- 你把 Codex 的默认 provider 从 A 切到了 B
- 旧 session 实际还在磁盘里，但在当前 provider 视角里“消失了”
- 你希望先本地修复可见性，再继续使用同一套历史
- 你需要可回滚、可恢复，而不是一次性脚本裸改文件

它不适合这些需求：

- 管理账号登录
- 管理 API Key 或 provider 凭据
- 迁移云端数据
- 替代 Codex 本身的会话管理逻辑

### 核心功能

| 功能 | 说明 |
| --- | --- |
| 当前 provider 检测 | 读取 `config.toml` 根级 `model_provider`；若未显式配置，则按 `openai` 作为隐式默认值处理 |
| Provider Radar | 从 `config.toml`、rollout 文件、SQLite、手动输入四个来源收集 provider 候选 |
| Sync History | 仅同步历史元数据，不改根级 `model_provider` |
| Switch + Sync | 先切换 `config.toml` 根级 provider，再执行同步 |
| 自动备份 | 每次同步前自动备份配置、SQLite 及 rollout 变更信息 |
| 备份恢复 | 可从历史备份恢复 `config.toml`、`state_5.sqlite` 与 rollout 原始状态 |
| 备份清理 | 支持保留最近 N 份备份，自动或手动清理旧备份 |
| Busy 文件检测 | 遇到被占用的 rollout 文件或正在使用的 SQLite，会跳过或终止并明确提示 |
| 自定义 Codex Home | 默认 `~/.codex`，也可切换到其他 Codex 工作目录 |
| 本地状态记忆 | 记住最近使用的 Codex Home、备选 provider、备份选择与保留数量 |

### 它是怎么工作的

一次完整同步大致会按下面的顺序执行：

1. 解析目标 `Codex Home`
   默认路径是 `~/.codex`，也支持你手动指定其他目录。

2. 读取根级 provider
   应用会从 `config.toml` 读取根级 `model_provider`。如果没有显式写这个字段，就按 `openai` 作为隐式默认值处理。

3. 扫描本地会话元数据
   应用会检查：
   - `sessions`
   - `archived_sessions`
   - `state_5.sqlite`

4. 生成变更前备份
   在真正写入之前，会先把配置、数据库和 rollout 原始信息保存到：
   `~/.codex/backups_state/provider-sync`

5. 重写 provider 元数据
   应用会把本地历史对齐到目标 provider，包括：
   - rollout 文件中的 provider 元数据
   - SQLite 中的 provider 相关记录

6. 可选更新根配置
   如果你选择了 `Switch + Sync`，应用会先更新 `config.toml` 根级 provider，再执行同步。

7. 自动清理旧备份
   同步完成后，会按你设置的保留数量自动尝试清理旧备份。

### 安全策略与防护设计

这个项目的重点不是“改得快”，而是“改得稳”。

- 每次同步、恢复、清理都会先申请独占锁，避免并发写入
- 写 SQLite 前会检测 `state_5.sqlite` 是否可写
- rollout 文件如果正被占用，会跳过并在日志中列出
- 备份会在写入前先创建，而不是写错后再补救
- 如果同步中途失败，已经改过的 rollout 变更会尽量回滚
- 恢复时会同时处理 `state_5.sqlite` 以及可能存在的 `-wal` / `-shm` 文件

### 使用前准备

在开始前，建议你先确认：

1. 你的 Codex 数据目录存在，通常是 `~/.codex`
2. `config.toml` 可正常读取
3. 如果你要使用 `Switch + Sync`，目标 provider 已经在 `config.toml` 的 `[model_providers.<id>]` 中声明
4. 最好关闭 Codex、Codex App 或 `app-server`，避免数据库和 rollout 文件被占用

### 下载与安装

如果你只是想直接使用：

1. 打开 [Releases](https://github.com/Triwalt/codex-provider-sync-mac/releases/latest)
2. 下载最新 release 页面中的 ZIP 构建产物
3. 解压得到 `.app`
4. 双击启动，或在终端中执行：

```bash
open "Codex Provider Sync.app"
```

### 从源码运行

环境要求：

- macOS 13+
- Swift 6 toolchain

直接运行：

```bash
swift run
```

打包为 `.app`：

```bash
./scripts/package_app.sh
```

构建产物会写到：

- `dist/Codex Provider Sync.app`
- `dist/Codex Provider Sync.zip`

### 使用步骤

1. 启动应用并确认 `Codex Home`
   默认是 `~/.codex`，也可以点 `Browse` 选择其他目录。

2. 点击 `Refresh`
   应用会扫描当前根 provider、已检测到的 provider、rollout 分布、SQLite 分布和现有备份。

3. 选择目标 provider
   可以从自动发现的 provider 中选择，也可以手动输入新增。

4. 决定是否更新根配置
   - 如果只想让历史对齐到某个 provider，不改根配置，使用 `Sync History`
   - 如果想同时切换当前默认 provider，启用 `Also update root model_provider in config.toml` 后使用 `Switch + Sync`

5. 设置备份保留数量
   应用会保留最近 N 次备份，并在同步后自动尝试清理旧备份。

6. 执行同步
   执行结束后，你可以在右侧和日志区看到：
   - 改动了多少 rollout 文件
   - 更新了多少 SQLite 记录
   - 是否跳过了 busy 文件
   - 备份保存在什么位置

7. 如有需要，恢复备份
   你可以从备份列表中选择某一份备份，再执行 `Restore Backup`。

### 读写范围

应用会读取这些内容：

- `config.toml`
- `sessions`
- `archived_sessions`
- `state_5.sqlite`
- `backups_state/provider-sync`

应用可能写入这些内容：

- rollout 文件中的 provider 元数据
- `state_5.sqlite`
- 根级 `config.toml` 的 `model_provider` 字段
- `backups_state/provider-sync` 下的新备份目录
- `~/Library/Application Support/codex-provider-sync/settings.json` 中的本地界面设置

### 项目结构

| 路径 | 说明 |
| --- | --- |
| `Sources/CodexSyncMacApp/CodexSyncMacApp.swift` | SwiftUI 入口与主界面 |
| `Sources/CodexSyncMacApp/AppModel.swift` | 应用状态、日志、选择项、执行流程、持久化设置 |
| `Sources/CodexSyncMacApp/SyncEngine.swift` | 同步、恢复、备份、SQLite 操作、锁与文件处理核心逻辑 |
| `scripts/package_app.sh` | 从 Swift Package 构建并组装 `.app` 与 ZIP |
| `Resources/Info.plist` | 应用包元信息 |

### 设计边界

为了让行为可预期，这个项目有明确边界：

- 只处理本地元数据修复，不做云端同步
- 不管理认证状态
- 不管理 provider 凭据
- 不直接替代 Codex 的官方逻辑
- 不承诺修复所有可见性问题，只聚焦 provider 标记错位这一类问题

### 致谢

- 同步原理、CLI 版本与 Windows GUI 思路来源：
  [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)

### 许可证

本项目使用 [MIT License](LICENSE)。

---

<a id="english"></a>

## English

### Overview

`Codex Provider Sync for Mac` is a native SwiftUI macOS app for a specific but frustrating local-state problem:

- you switched Codex to a different root `model_provider`
- your old sessions still exist on disk
- but those sessions are no longer visible under the provider you are now using

This app repairs that visibility mismatch by working across all relevant local metadata layers:

- `~/.codex/config.toml`
- `sessions` and `archived_sessions` rollout files
- `state_5.sqlite`

The goal is simple: make local history visible again under the provider you want, while keeping the workflow backup-first and reversible.

### Principle Credit

The synchronization principle in this repository comes from [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync).

This project keeps the core idea intact:

- repair rollout metadata and SQLite metadata together
- preserve the practical provider-history repair workflow
- repackage that idea as a native macOS desktop experience

In other words:

> this repo is a Mac-native reimplementation of the same core repair idea, not a brand-new unrelated algorithm.

### When This App Helps

This app is a good fit if:

- you changed the active Codex provider
- old sessions still exist locally but appear hidden
- you want a local repair tool with backup and restore
- you prefer a native Mac app over an ad-hoc script flow

This app is not intended for:

- authentication management
- API key or credential management
- cloud migration
- replacing Codex itself

### Core Capabilities

| Capability | Details |
| --- | --- |
| Current provider detection | Reads the root `model_provider` from `config.toml`; if absent, treats `openai` as the implicit default |
| Provider Radar | Collects provider candidates from config, rollout files, SQLite, and manual entries |
| Sync History | Rewrites history metadata without changing the root provider in `config.toml` |
| Switch + Sync | Updates the root provider first, then synchronizes local history |
| Automatic backups | Creates a managed backup before every sync |
| Backup restore | Restores `config.toml`, SQLite files, and original rollout metadata |
| Backup pruning | Keeps the newest N backups automatically or on demand |
| Busy file detection | Detects locked rollout files and SQLite access conflicts |
| Custom Codex Home | Defaults to `~/.codex`, but supports other Codex directories |
| Local state memory | Remembers recent homes, selected providers, backup choices, and retention settings |

### How It Works

A typical sync flow looks like this:

1. Resolve the target Codex Home
   By default the app works on `~/.codex`, but you can point it elsewhere.

2. Read the current root provider
   The app checks `config.toml`. If no root `model_provider` is present, it treats `openai` as the implicit default.

3. Inspect local history metadata
   The app scans:
   - `sessions`
   - `archived_sessions`
   - `state_5.sqlite`

4. Create a backup before writing
   Backups are stored under:
   `~/.codex/backups_state/provider-sync`

5. Rewrite provider metadata
   The app aligns local history to the selected provider by updating:
   - provider metadata inside rollout files
   - provider-related rows inside SQLite

6. Optionally update root config
   If you choose `Switch + Sync`, the root `model_provider` is changed before the sync is applied.

7. Prune older backups
   After a successful run, the app attempts to keep only the newest backups according to your retention setting.

### Safety Model

This project is designed to be cautious, not just convenient.

- sync, restore, and prune operations acquire an exclusive lock first
- SQLite writability is checked before mutation
- busy rollout files are skipped and explicitly reported
- backups are created before modifications begin
- applied rollout changes are rolled back on failure when possible
- restore also handles SQLite sidecar files such as `-wal` and `-shm`

### Before You Start

Recommended checklist:

1. your Codex data directory exists, usually `~/.codex`
2. `config.toml` is present and readable
3. if you want `Switch + Sync`, the target provider is already declared under `[model_providers.<id>]`
4. Codex, Codex App, or `app-server` is closed so files are less likely to be busy

### Download and Install

If you just want to use the app:

1. Open [the latest release page](https://github.com/Triwalt/codex-provider-sync-mac/releases/latest)
2. Download the ZIP asset from that release
3. Extract the archive to get the `.app`
4. Launch it by double-clicking, or run:

```bash
open "Codex Provider Sync.app"
```

### Run from Source

Requirements:

- macOS 13+
- Swift 6 toolchain

Run directly:

```bash
swift run
```

Package as an `.app`:

```bash
./scripts/package_app.sh
```

Packaged outputs are written to:

- `dist/Codex Provider Sync.app`
- `dist/Codex Provider Sync.zip`

### Typical Usage

1. Launch the app and confirm `Codex Home`
   The default is `~/.codex`, but you can browse to another directory.

2. Click `Refresh`
   The app scans the current provider, detected providers, rollout distribution, SQLite distribution, and available backups.

3. Pick a target provider
   You can use an automatically detected provider or add one manually.

4. Decide whether to update root config
   - use `Sync History` if you only want to align history metadata
   - use `Switch + Sync` if you also want to switch the root provider in `config.toml`

5. Set backup retention
   The app keeps the newest N backups and can prune older ones automatically.

6. Run the operation
   The log and summaries show:
   - how many rollout files changed
   - how many SQLite rows changed
   - whether any busy files were skipped
   - where the backup was stored

7. Restore if needed
   Choose a backup entry and run `Restore Backup`.

### Read and Write Scope

The app reads:

- `config.toml`
- `sessions`
- `archived_sessions`
- `state_5.sqlite`
- `backups_state/provider-sync`

The app may write:

- provider metadata inside rollout files
- `state_5.sqlite`
- the root `model_provider` in `config.toml`
- new managed backup directories under `backups_state/provider-sync`
- local UI settings in `~/Library/Application Support/codex-provider-sync/settings.json`

### Project Structure

| Path | Purpose |
| --- | --- |
| `Sources/CodexSyncMacApp/CodexSyncMacApp.swift` | SwiftUI app entry and main interface |
| `Sources/CodexSyncMacApp/AppModel.swift` | App state, logs, provider selection, actions, and persisted settings |
| `Sources/CodexSyncMacApp/SyncEngine.swift` | Core sync, restore, backup, SQLite, locking, and file mutation logic |
| `scripts/package_app.sh` | Builds the release binary and assembles the `.app` bundle and ZIP |
| `Resources/Info.plist` | App bundle metadata |

### Scope Boundaries

To keep behavior predictable, this project stays intentionally narrow:

- local metadata repair only
- no authentication management
- no provider credential management
- no cloud synchronization
- no attempt to replace Codex's official behavior
- focused specifically on provider-marker mismatch issues

### Credits

- Original synchronization principle, CLI workflow, and Windows GUI concept:
  [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)

### License

This project is released under the [MIT License](LICENSE).
