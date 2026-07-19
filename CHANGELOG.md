# Changelog

## 1.1.6 (unreleased)

- Added isolated personal/work account profiles for Codex, Claude Code, and
  GitHub Copilot across the supported experience.
- Added exact per-account GitHub Copilot open, working, and waiting cloud-agent
  session counts. Codex and Claude Code explicitly show unavailable when no
  equivalent provider data exists.
- Added secure iPhone/iPad and dependent Apple Watch companions with bounded,
  credential-free WatchConnectivity payloads.
- Isolated the fork's bundle IDs, App Group, deep links, Keychain services,
  local files, logs, and LaunchAgents from the original project.
- Hardened credential storage, provider redirects, cookies, subprocesses,
  account deletion, data migration, logs, and update trust.
- Fixed usage-window, billing-period, date-boundary, formatting, refresh-race,
  WebView-lifecycle, and snapshot-retirement bugs.
- Added Apple privacy manifests, distribution automation, unsigned preflight
  packages, signed-disk-image/notarization guidance, and release checklists.

Original AgentLimits was created by Nihondo and remains credited under the MIT
license: https://github.com/Nihondo/AgentLimits
