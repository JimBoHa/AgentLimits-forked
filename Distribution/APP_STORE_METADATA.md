# App Store Connect Draft

This is a preparation worksheet, not a substitute for the live App Store
Connect form. Reconfirm every answer against the exact submitted binary.

## Product

- Name: AgentLimits Forked
- iOS bundle ID: `com.jimboha.agentlimits.ios`
- Embedded Watch bundle ID: `com.jimboha.agentlimits.ios.watchkitapp`
- Version/build: 1.1.6 (16)
- Watch relationship: dependent companion; not independently distributed
- Suggested category: Developer Tools or Productivity
- Copyright: Copyright © 2025-2026 Nihondo
- Content rights: the project is distributed under Nihondo's MIT license; the
  original project is credited in the app resources, repository, and README.

## URLs

- Support: `https://github.com/JimBoHa/AgentLimits-forked/issues`
- Privacy: `https://github.com/JimBoHa/AgentLimits-forked/blob/main/PRIVACY.md`
- Source/original attribution:
  `https://github.com/Nihondo/AgentLimits`

A stable HTTPS site is preferable to a repository blob before final review,
but both URLs above are public and require no account to read.

## Privacy draft

- Tracking: No
- Maintainer advertising or analytics: None
- Data collected by the maintainer: None
- Provider requests: initiated for app functionality and sent directly to the
  selected provider; the maintainer has no server or access to those requests
- Privacy manifests: no tracking; no collected-data types; UserDefaults reason
  `CA92.1` for app-only settings/cache

Reconfirm Apple's current definitions for data processed by third parties when
answering the live privacy questionnaire. The shipping app and privacy policy
must remain consistent with the answers.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the iOS and Watch bundles. The
current app relies on encryption supplied by Apple's operating systems for
HTTPS and Keychain use and contains no custom cryptographic implementation.
Reconfirm this answer if cryptography changes.

## Review notes draft

AgentLimits Forked lets people define multiple named Codex, Claude Code, and
GitHub Copilot accounts. The initial iPhone/Watch companion displays exact
GitHub Copilot cloud-agent session counts when the person supplies a
least-privilege GitHub credential. Codex and Claude Code counts are marked
unavailable because those providers do not expose an equivalent API.

The GitHub credential is account-scoped, device-only Keychain data. It is sent
only to `api.github.com`; redirects are rejected. The dependent Watch app never
receives credentials or performs provider networking. It receives only bounded
status snapshots and UUID-only refresh requests.

If App Review needs a working GitHub account or credential, enter it only in
App Store Connect's protected review-information fields. Never commit it, add
it to screenshots, place it in review notes visible publicly, or send it to the
maintainer's infrastructure.

## Required media and remaining fields

- iPhone screenshots for every required display class
- iPad screenshots for every required display class
- Apple Watch screenshots for every required display class
- Description, subtitle, keywords, promotional text, and localized metadata
- Contact name, email, and phone
- Age-rating questionnaire
- Pricing, tax category, countries/regions, and release method
- TestFlight compliance and tester notes
