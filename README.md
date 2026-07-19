> Fork notice: Originally created by [Nihondo](https://github.com/Nihondo) at [Nihondo/AgentLimits](https://github.com/Nihondo/AgentLimits). This fork preserves full credit to the original author and project.

# AgentLimits

**In Development**

AgentLimits is a macOS Sonoma+ menu bar app with Notification Center widgets. It shows usage limits for ChatGPT Codex / Claude Code (5-hour + weekly, or monthly when the provider returns a monthly window), GitHub Copilot (monthly premium requests), and ccusage token usage.

![](./images/agentlimit_sample.png)

## Download
Fork releases: [JimBoHa/AgentLimits-forked releases](https://github.com/JimBoHa/AgentLimits-forked/releases)

## Quick Start (First-Time Setup)
1. Run AgentLimits.
2. Add widgets in Notification Center.
3. Open **AgentLimits Settings...** from the menu bar.
4. In **Usage**, choose Codex, Claude Code, or Copilot, choose or add an account, set refresh interval (1–10 minutes), open the bottom login panel (`▲`), then sign in.
5. Use the menu bar **Display Mode** to switch Used/Remaining, and **Refresh Now** for manual updates.

## What It Tracks
- **Usage limits (Codex / Claude Code):** 5-hour + weekly usage, or monthly usage when the provider returns a monthly window, via internal APIs.
  - Codex: `https://chatgpt.com/backend-api/wham/usage`
  - Claude Code: `https://claude.ai/api/organizations/{orgId}/usage`
- **Usage limits (GitHub Copilot):** Monthly premium interaction quota via entitlement API.
  - Copilot: `https://github.com/github-copilot/chat/entitlement`
- **Token usage (ccusage):** daily/weekly/monthly tokens and cost via a preinstalled CLI.
  - Codex: `ccusage codex daily`
  - Claude Code: `ccusage claude daily`
- **Premium request usage (Copilot):** daily premium request count and cost via WebView.
  - API: `https://github.com/settings/billing/usage_table` (fetched automatically with Copilot usage)
- **Multiple accounts:** Each provider can have named personal, work, or other accounts with separate login sessions, quota snapshots, token snapshots, and optional local CLI data directories.
- **Current Copilot cloud-agent sessions:** Per-account open, working, and waiting session counts from the [GitHub Agent Tasks API](https://docs.github.com/en/rest/agent-tasks/agent-tasks). Counts include only repositories visible to that account’s credential; Codex and Claude Code do not currently expose an equivalent count.

## Menu Bar Display
- Two-line layout per provider in the icon area
  - Line 1: provider name
  - Line 2: `X% / Y%` (5-hour / weekly)
  - For monthly-only providers such as Copilot or some Codex plans: `X%` (monthly)
- Display mode: **Used** or **Remaining** (shared across app and widgets)
- Status colors are based on pacemaker comparison when available (colors are configurable in **Notification** settings)
- Status colors in the menu bar are automatically darkened or lightened to match the current menu bar text color.
- Pacemaker indicator: optionally shows `<used>%↑` when over pace
- Toggle icon visibility per provider in **Usage** settings
- **Hide menu bar icon**: completely hides the menu bar icon. While hidden, double-click the app icon in Finder (or open via Spotlight / `open -a AgentLimits`) while it is still running to temporarily show the icon and open Settings. Closing the Settings window hides the icon again.
- Provider display order (Codex / Claude Code / Copilot) is configurable in **Usage** settings (**Display Order**)

### Menu Dashboard
When you open the menu bar menu, a dashboard appears at the top showing per-provider usage at a glance:
- Header: provider name · remaining time (5h window) · days until weekly reset, or monthly reset for monthly-only providers
- **Usage bar**: linear progress bar color-coded by usage level; when pacemaker is exceeded, the bar is segmented (green → orange → red) matching the widget donut ring behavior
- **Pacemaker bar**: divided into time segments (5h: 5 segments, weekly: 7 segments, monthly: single continuous bar) with gaps, matching the widget inner ring
- Clicking a dashboard row opens the provider's usage page in the browser
- Dashboard visibility is configurable per provider in **Usage** settings (**Show dashboard in menu**)
- Menu also includes: **Display Mode**, **Language** (System/Japanese/English), **Wake Up → Run Now**, **Start app at login**, and **Check for Updates...**

![](./images/agentlimits_menu.png)


## Pacemaker
Pacemaker shows a time-based usage benchmark to help you stay on track.

- **Calculation**: Elapsed percentage of the usage window (e.g., 50% = halfway through the 5h or weekly window)
- **Comparison**: Green = on track or ahead, Orange = slightly over pace, Red = 10%+ over pace
- **Menu Bar**: Shows `<used>% (<pacemaker>)%` with toggleable pacemaker value display (**Pacemaker** settings)
- **Widget**: Outer ring = actual usage, inner ring = pacemaker percentage (shown when pacemaker data is available)
  - When usage exceeds pacemaker in **used mode only**, the outer ring is segmented and color-coded (green → orange → red) to show warning/danger zones (toggleable in **Pacemaker** settings, enabled by default)
- **Thresholds**: Warning/danger delta thresholds are configurable in **Pacemaker** settings
- **Colors**: Pacemaker ring/text colors are configurable in **Pacemaker** settings

## Widgets
### Usage Widgets (Codex / Claude Code)
- Dual donut gauge: 5-hour and weekly windows side by side
- Some Codex plans may show a single centered monthly donut when the Codex API returns only a monthly window
- Color-coded percentage based on usage level and display mode
- Update time shown as `HH:mm` (or `--:--` if older than 24h)

### Usage Widget (GitHub Copilot)
- Single centered donut gauge: monthly premium interaction quota
- Pacemaker inner ring divided into weekly segments (4–5 segments based on billing period)
- Center label: `1mo`
- Color-coded percentage based on usage level and display mode
- Update time shown as `HH:mm` (or `--:--` if older than 24h)

### Token Usage Widgets (Codex / Claude Code)
- **Small:** today / this week / this month summary (cost + tokens)
- **Medium:** summary + GitHub-style heatmap
  - 7 rows (Sun–Sat) × 4–6 columns (weeks)
  - 5 levels by quartile distribution
  - Weekday labels (Mon, Wed, Fri)
  - Desktop pinned mode support (accented / grayscale)
- Widget tap action is configurable (default opens `https://ccusage.com/`)

### Premium Requests Usage Widget (GitHub Copilot)
- **Small:** today / this week / this month summary (cost + premium requests)
- **Medium:** summary + GitHub-style heatmap
- Data is fetched automatically when Copilot usage is refreshed (via WebView, no CLI required)
- Widget tap action is configurable (default opens `https://ccusage.com/`)

## Settings Guide
### Usage
1. Open **Usage**.
2. Select Codex, Claude Code, or Copilot.
3. Choose an account, or click **Manage…** to add, rename, enable, disable, or remove named accounts. Codex and Claude Code accounts can use separate local CLI data directories.
4. Choose refresh interval (1–10 minutes).
5. Toggle **Show in menu bar** to show the selected account's usage percentage in the icon area.
6. Toggle **Show dashboard in menu** to show/hide the provider's row in the menu dashboard.
7. Drag rows in **Display Order** to change the order of providers in the menu bar icon and dashboard.
8. Click the bottom login bar (`▲`) to expand the selected account's embedded WebView panel.
9. Sign in via the embedded WebView (chatgpt.com / claude.ai / github.com). Each newly added account has isolated website storage and cached usage snapshots.
10. For a Copilot account, use the key button beside **Current Sessions** (or in **Manage…**) to save a fine-grained PAT or GitHub App user access token. Grant only repository **Agent tasks: Read** permission. The credential stays in this device’s non-synchronizing Keychain; the API is currently a GitHub public preview.
11. Use **Clear Data** to remove login data, website storage, cached usage snapshots, and saved session credentials for all managed accounts if sign-in gets stuck or you want a full reset.

Accounts migrated from older AgentLimits versions may temporarily share the legacy website session. The app warns before removing a migrated account because doing so signs out every migrated account that still shares that session; newly added isolated accounts are unaffected. Removing a Copilot account also deletes its account-scoped session credential from Keychain.

Current-session counts are fetched independently for each named Copilot account. A missing, rejected, or under-scoped credential is shown as unavailable—not zero—and failed refreshes label prior counts as last known instead of presenting them as current.

### ccusage
1. Open **ccusage**.
2. Select provider (Codex / Claude Code).
3. Select the named account to inspect. Account selection is shared with **Usage** and the widgets.
4. For multiple Codex or Claude Code accounts, set a unique CLI data directory for each additional account in **Usage → Manage…**. AgentLimits passes it to ccusage as [`CODEX_HOME`](https://ccusage.com/guide/codex/) or [`CLAUDE_CONFIG_DIR`](https://ccusage.com/guide/claude/) only for that child process.
5. Choose refresh interval (1–10 minutes).
6. Enable periodic fetch and set additional CLI args if needed.
7. Use **Test Now** to verify the selected account's CLI execution.
8. For Copilot: billing data is fetched automatically and stored for the exact account whose WebView produced it — just enable the toggle.

### Wake Up
1. Open **Wake Up**.
2. Select provider (Codex / Claude Code). Note: Copilot is not supported.
3. Enable schedule.
4. Choose hours to run (0–23).
5. Use **Test Now** to verify CLI execution.

### Notification
1. Open **Notification**.
2. Request notification permission (first time only).
3. Select provider (Codex / Claude Code / Copilot).
4. Configure thresholds for each window (5-hour/weekly for Codex/Claude Code when available; monthly-only Codex and Copilot use the primary/monthly threshold).
5. Adjust usage colors (donut + status colors) if needed.

### Pacemaker
1. Open **Pacemaker**.
2. Toggle the menu bar pacemaker value display.
3. Toggle the widget ring warning segments (color-coded segments when exceeding pacemaker).
4. Adjust pacemaker warning/danger deltas.
5. Customize pacemaker ring/text colors.

### Advanced
1. Open **Advanced**.
2. Set full paths for `codex`, `claude`, and `ccusage` if needed (blank = resolve via PATH).
3. Review PATH resolution results.
4. Choose widget tap action (open website / refresh data).
5. Toggle **Hide menu bar icon** to completely hide the icon from the menu bar. To access settings while hidden, double-click the app icon while it is still running.
6. Copy the bundled status line script path if needed.

## Wake Up (CLI Scheduler)
- Runs scheduled commands:
  - `codex exec --skip-git-repo-check "hello"`
  - `claude -p "hello"`
- LaunchAgent plist: `~/Library/LaunchAgents/com.dmng.agentlimit.wakeup-*.plist`
- Logs: `/tmp/agentlimit-wakeup-*.log`
- Additional CLI arguments are supported per provider.

## Claude Code Status Line Script
![](./images/agentlimits_statusline_sample.png)
- Bundled script for Claude Code status line integration (path shown in **Advanced → Bundled Scripts**)
- Reads Claude Code usage snapshot + App Group settings (display mode, language, thresholds, colors)
- Outputs a single line with 5-hour/weekly usage, reset times, and update time
- Options: `-ja`, `-en`, `-r` (remaining), `-u` (used), `-p` (pacemaker), `-i` (usage + pacemaker inline), `-d` (debug)
- Requires `jq` (`brew install jq`)

## Advanced: Storage (App Group)
Snapshots are stored in the App Group container:
```
~/Library/Group Containers/group.com.dmng.agentlimit/Library/Application Support/AgentLimit/
├── accounts/<account-uuid>/
│   ├── usage_snapshot*.json
│   └── token_usage_*.json
├── usage_snapshot.json
├── usage_snapshot_claude.json
├── usage_snapshot_copilot.json
├── token_usage_codex.json
├── token_usage_claude.json
└── token_usage_copilot.json
```

## Notes / Troubleshooting
- Internal APIs may change without notice.
- ccusage output changes may break parsing.
- Widget refresh can be throttled by macOS.
- Threshold notifications require permission.
- Install ccusage explicitly first (for example, `npm install -g ccusage`) and review upgrades before applying them. AgentLimits never downloads or runs `ccusage@latest` automatically.
- CLI execution uses fixed `/bin/zsh -f` wrappers and prefixes PATH with `/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH`.
- Account-specific CLI data directories are read-only inputs to ccusage. AgentLimits never deletes or modifies them when an account is removed or **Clear Data** is used.
- Full-path overrides in **Advanced** take precedence.
- Claude Code logins may require multiple attempts.
- The Claude Code status line script requires `jq`.
- Settings window minimum height is `620` to keep the bottom login panel visible.

## Automatic Updates

Automatic updates are disabled in this fork until a fork-owned Sparkle appcast and EdDSA signing key are configured. Builds do not trust or install updates from the original project's update channel. Until fork signing is configured, use the fork's GitHub releases page.
