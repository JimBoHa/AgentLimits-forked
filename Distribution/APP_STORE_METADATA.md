# App Store Connect Submission Draft

This worksheet covers the iPhone, iPad, and dependent Apple Watch app. It is
not a substitute for the live App Store Connect form. Reconfirm every answer
against the exact signed binary submitted to Apple.

Fields marked **BLOCKED** require the distributor's legal or Apple Developer
account information and must not be guessed or committed if sensitive.

## App record

- Name: `AgentLimits Forked`
- Primary language: English (U.S.)
- Bundle ID: `com.jimboha.agentlimits.ios`
- SKU: choose a stable internal value in App Store Connect, for example
  `agentlimits-forked-ios`
- Version/build: `1.1.6 (16)`
- Embedded Watch bundle ID: `com.jimboha.agentlimits.ios.watchkitapp`
- Watch relationship: dependent companion; not independently distributed
- Primary category: Developer Tools
- Secondary category: Productivity
- Content rights: **BLOCKED** on distributor confirmation — the conservative
  declaration is that the app accesses third-party provider data for
  user-requested functionality; verify that the MIT license, provider API
  terms, trademark use, and each selected storefront permit the exact release
- Copyright: **BLOCKED** — enter `2026 <person or legal entity that owns the
  fork's exclusive rights>`; do not name Nihondo unless Nihondo is submitting
  the app or has transferred those rights
- Price: suggested `Free`; **BLOCKED** on distributor decision
- Availability and release method: **BLOCKED** on distributor decision
- Digital Services Act trader status and regional compliance: **BLOCKED** on
  distributor/account information

## English (U.S.) product-page copy

### Subtitle

`Track AI account sessions`

### Promotional text

`Keep personal and work developer accounts separate, view GitHub Copilot Agent Tasks activity, and check account status from Apple Watch.`

### Keywords

`codex,claude,copilot,quota,usage,developer,accounts,sessions,github,limits,watch`

Do not add `AgentLimits` or the distributor name to the keywords; the app name
and developer name are already indexed. Recheck the comma-separated field is
at most 100 UTF-8 bytes before pasting it into App Store Connect.

### Description

Track current cloud-agent activity across named developer accounts from
iPhone, iPad, and Apple Watch.

AgentLimits Forked keeps personal, work, and other profiles separate for Codex,
Claude Code, and GitHub Copilot. For GitHub Copilot accounts, add a
least-privilege credential to see exact open, working, and waiting Agent Tasks
session counts. Providers without an equivalent current-session API are
clearly shown as unavailable instead of zero.

Highlights:

- Multiple named accounts for every provider
- Per-account GitHub Copilot session activity
- iPhone and iPad account management
- A companion Apple Watch status view
- Device-only, non-synchronizing credential storage
- No ads, analytics, tracking, or maintainer-operated server

The Apple Watch companion never receives provider credentials. It receives
only bounded account status snapshots from the paired iPhone.

AgentLimits Forked is an independent open-source fork of Nihondo's original
AgentLimits project and is not affiliated with OpenAI, Anthropic, or GitHub.

Some features require your own provider account and may depend on provider
APIs, permissions, availability, and terms.

### What's New

First iPhone, iPad, and Apple Watch release of AgentLimits Forked. Manage
multiple named provider accounts, view supported current-session counts, and
check sanitized account status from Apple Watch.

## URLs

- Privacy policy:
  `https://github.com/JimBoHa/AgentLimits-forked/blob/main/PRIVACY.md`
- Marketing/source:
  `https://github.com/JimBoHa/AgentLimits-forked`
- Original project attribution:
  `https://github.com/Nihondo/AgentLimits`
- Support URL: **BLOCKED** — publish a stable HTTPS page that includes actual
  contact information required by applicable law, such as the distributor's
  support email and, where required, legal address and telephone number
- Privacy choices URL: not required because the app has no maintainer-collected
  data and offers no tracking or sale/sharing choices; use the privacy-policy
  URL if App Store Connect requires a value
- Age suitability URL: optional; leave blank unless a dedicated page is
  published

The GitHub issues page may be linked from the support page, but it is not by
itself a complete support URL because it contains no distributor contact
information.

## App privacy draft

- Tracking: No
- Data used to track the user: None
- Data linked to the user and collected by the developer: None
- Data not linked to the user and collected by the developer: None
- Maintainer advertising or analytics: None
- Provider requests: initiated for app functionality and sent directly from
  the device to the selected provider; the maintainer operates no receiving
  server and does not retain those requests
- GitHub credential: device-only, non-synchronizing Keychain data used solely
  for the requested GitHub API operation
- Watch transfer: bounded status values and account UUIDs only; no credentials,
  provider cookies, or local CLI data
- Privacy manifests: no tracking; no collected-data types; UserDefaults reason
  `CA92.1` for app-only settings and cache
- Release enforcement: `VALIDATE_PRODUCT=YES` plus
  `Scripts/app-store-product-validation.sh` verifies the manifest declarations
  for these privacy claims, encryption declarations, product IDs/versions,
  launch/icon metadata, the embedded dependent Watch relationship, and the
  exact executable-code inventory in unsigned and signed workflows

Under Apple's definitions, data processed only on-device is not "collected."
Data sent to a third party solely to service a user request and not retained
longer than necessary may also fall outside collection, but the live answers
must be reconfirmed against the final implementation and every integrated
third-party SDK.

## Age-rating questionnaire draft

Expected result: `4+` on current Apple operating systems, subject to App Store
Connect's calculation.

- Parental controls: No
- Age assurance: No
- Unrestricted web access: No — product/privacy links leave the app for the
  system browser; the iOS/watchOS app does not provide a freely browsable
  embedded browser
- User-generated content: No
- Social media: No
- Social media disabled for users under 13: No / not applicable
- Messaging and chat: No
- Advertising: No
- Profanity or crude humor: None
- Horror or fear themes: None
- Alcohol, tobacco, or drug use or references: None
- Medical or treatment information: None
- Health or wellness topics: None
- Mature or suggestive themes: None
- Sexual content or nudity: None
- Graphic sexual content and nudity: None
- Cartoon or fantasy violence: None
- Realistic violence: None
- Prolonged graphic or sadistic realistic violence: None
- Guns or other weapons: None
- Gambling: No
- Simulated gambling: None
- Contests: None
- Loot boxes: No
- Made for Kids: No
- Override to higher rating: Not applicable

Do not interpret account labels or provider status as broadly distributed
user-generated content: the app stores and shows them only to that user.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the iOS and Watch bundles. The
app relies on encryption supplied by Apple's operating systems for HTTPS and
Keychain use and contains no custom cryptographic implementation. Reconfirm
this answer if cryptography or dependencies change.

## Review contact

- First name: **BLOCKED**
- Last name: **BLOCKED**
- Email: **BLOCKED**
- Phone: **BLOCKED**
- Sign-in required: no maintainer-operated login; a reviewer can inspect
  account management and unsupported-provider states without a credential
- Demo GitHub credential: optional and **BLOCKED**; if supplied, enter it only
  in App Store Connect's protected review-information fields

Never commit a review credential, place it in screenshots, add it to public
review notes, or send it to maintainer infrastructure.

## Review notes draft

AgentLimits Forked lets people define multiple named Codex, Claude Code, and
GitHub Copilot accounts. The iPhone and Apple Watch companion displays exact
GitHub Copilot cloud-agent session counts when the reviewer supplies a
least-privilege GitHub credential. Codex and Claude Code counts are marked
unavailable because those providers do not expose an equivalent current-session
API.

To exercise the credential path on iPhone or iPad, open the GitHub Copilot
account's More menu, choose Manage Credential, and save a fine-grained personal
access token or GitHub App user access token with only repository Agent Tasks
read access. Then select Refresh. The API is a GitHub public preview, and the
visible repository scope determines the returned counts.

The GitHub credential is account-scoped, device-only Keychain data. It is sent
only to `api.github.com`; redirects are rejected. The dependent Watch app never
receives credentials or performs provider networking. It receives only bounded
status snapshots and sends UUID-only refresh requests to the paired iPhone.

The app contains no purchases, subscriptions, advertising, analytics,
tracking, or maintainer-operated backend.

## Screenshot set

Upload one consistent, truthful screenshot set with no alpha channel:

- iPhone 17 Pro Max, 6.9-inch portrait: use the simulator's native accepted
  size (one of `1260x2736`, `1290x2796`, or `1320x2868`)
- iPad Pro 13-inch (M5), portrait: `2064x2752`
- Apple Watch Series 11 (46mm): `416x496`; use this same Watch size in every
  localization

Suggested sequence:

1. All three provider account sections and availability states
2. Personal and work GitHub Copilot accounts shown together
3. Exact open, working, and waiting session counts using deterministic sample
   data clearly limited to screenshot/test builds
4. Credential privacy and clear-session-data controls
5. Apple Watch account status and session breakdown

Before upload, verify dimensions, color profile, no alpha/transparency, no
credentials or personal identifiers, and no clipped or obscured controls.

## Remaining live-account work

- Create the App Store Connect record and choose its SKU
- Enter the distributor's copyright owner, support contact, review contact,
  DSA status, price, tax category, availability, and release method
- Publish a stable support page with legally sufficient contact information
- Complete agreements, banking, tax, and regional compliance as applicable
- Paste and review the localized metadata
- Upload final screenshots from the exact release UI
- Reconfirm privacy, age-rating, content-rights, and export-compliance answers
- Select the signed build and complete App Review submission
- Add protected review credentials only if App Review requests them

## Apple references

- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Age-rating categories and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)
- [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
