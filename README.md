# Codex Provider Sync for Mac

Native macOS app for repairing Codex history visibility after switching `model_provider`.

This project is a lightweight SwiftUI port of the core idea behind [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync): update both the rollout files and `state_5.sqlite` so older sessions become visible again under the target provider.

It is intentionally focused on macOS and native desktop UX.

## What It Does

- Reads the root `model_provider` from `~/.codex/config.toml`
- Scans `sessions` and `archived_sessions` for `rollout-*.jsonl`
- Updates provider metadata in `state_5.sqlite`
- Creates backups before every sync
- Restores from previous backups
- Prunes old backups automatically or manually
- Skips busy rollout files and reports them in the log

## Why This Exists

There are already broader Codex management tools on GitHub, but this app is intentionally narrower:

- native macOS app
- lightweight SwiftUI codebase
- focused on provider/history visibility repair
- no Node.js or .NET runtime required for end users

## Features

- Custom `Codex Home`
- Current root provider detection
- Provider discovery from config, rollout files, SQLite, and manual entries
- Sync history to the selected provider
- Optional root-provider switch in `config.toml`
- Rollout and SQLite provider distribution summaries
- Backup browser, restore flow, and retention controls

## Requirements

- macOS 13+
- Swift 6 toolchain to build from source

## Run from Source

```bash
swift run
```

## Package as `.app`

```bash
./scripts/package_app.sh
```

The packaged outputs are written to:

- `dist/Codex Provider Sync.app`
- `dist/Codex Provider Sync.zip`

## Project Structure

- `Sources/CodexSyncMacApp/SyncEngine.swift`
  Native sync, backup, restore, and SQLite logic
- `Sources/CodexSyncMacApp/AppModel.swift`
  App state, persistence, and action orchestration
- `Sources/CodexSyncMacApp/CodexSyncMacApp.swift`
  SwiftUI interface
- `scripts/package_app.sh`
  Build and package helper

## Notes

- This project is not affiliated with OpenAI.
- It focuses on local metadata repair only.
- It does not manage authentication, account switching, or provider-side credentials.

## Credits

- Original CLI and Windows GUI concept: [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)

## License

MIT
