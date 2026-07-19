# AgentLimits Forked Privacy Policy

Effective date: July 19, 2026

Policy version: 1.0

This policy applies to AgentLimits Forked for macOS, iOS, and watchOS,
distributed from
[JimBoHa/AgentLimits-forked](https://github.com/JimBoHa/AgentLimits-forked).

## Summary

AgentLimits Forked has no advertising, analytics, telemetry, or cross-app
tracking. The app and its maintainer do not collect personal data. The
maintainer does not operate a server that receives your accounts, credentials,
usage information, or session counts.

AgentLimits processes data on your device and, when needed for a feature you
request, communicates directly with the service provider you selected. Those
provider requests are subject to that provider's privacy policy and account
terms.

## Data Processed on Your Device

Depending on platform and enabled features, the app may process:

- Account labels and locally generated account identifiers.
- Usage-limit, token-usage, billing-usage, and current-session results.
- Refresh times, cached results, and app preferences.
- Website session cookies created when you sign in to a provider through the
  macOS app.
- Local Codex or Claude Code usage files through `ccusage`, if you enable that
  feature on macOS.
- A GitHub credential that you voluntarily save for Copilot cloud-agent session
  counts.

This information supports app features only. AgentLimits does not use it to
build a profile, identify you across apps or websites, or deliver advertising.

## Credentials

### GitHub Credential on iPhone and iPad

Each saved GitHub fine-grained personal access token or GitHub App user access
token is stored for its specific account in Apple Keychain. It uses the
`WhenUnlockedThisDeviceOnly` accessibility class and is explicitly marked as
non-synchronizing. It does not sync through iCloud Keychain and is not included
in data restored to another device or sent to Apple Watch.

When you refresh Copilot cloud-agent session counts, AgentLimits sends this
credential directly to `https://api.github.com` over HTTPS as an authorization
credential. The app restricts this request to GitHub's API host and rejects
redirects. The credential is never sent to the maintainer or a
developer-operated service. GitHub may process and log the request under its
own policies.

Use a credential with only the permissions needed by the feature. You can
remove one account's credential or use **Clear Session Data** to remove all
session credentials.

### Website Sessions on macOS

Provider sign-in sessions and cookies created by the embedded web views remain
in app-managed website storage on your Mac. They are sent directly to the
relevant provider as part of normal HTTPS requests. Account sessions are
isolated where the app supports isolation. The app discloses any migrated
legacy session that remains shared between accounts.

## Network Requests and Third Parties

AgentLimits may communicate directly with services required for enabled
features, including:

- OpenAI services for Codex usage information.
- Anthropic services for Claude Code usage information.
- GitHub services for Copilot quota, billing usage, and Agent Tasks session
  counts.
- Links you choose to open in a browser.

The maintainer does not receive these requests. Service providers may receive
your IP address, account credential or session cookie, request metadata, and
feature-specific API request under their own privacy policies. AgentLimits does
not sell, rent, or share your information with advertisers or data brokers.

## Apple Watch

The Apple Watch companion receives only the account display information,
availability, aggregate session counts, and timestamps needed to show its
status view. It does not receive GitHub credentials, provider cookies, or local
CLI data. Watch data stays in the watch app's local container and is not sent
to the maintainer.

## Retention and Deletion

AgentLimits retains local settings and cached results until they are replaced
or you remove them. There is no developer-side copy and therefore no
developer-side retention period or deletion request process.

Available deletion controls include:

- Remove an account to delete its account-scoped cached data and saved session
  credential, where applicable.
- Use **Clear Session Data** on iOS to delete all saved GitHub credentials and
  current-session counts while keeping account names.
- Use the macOS clear-data controls to remove app-managed provider website data,
  cached usage data, and saved session credentials.
- Remove the app to delete its app-container data. Keychain items can survive
  app removal, so use the in-app clear or account-removal control before
  uninstalling if you want to ensure credentials are deleted.
- Remove the watch app to delete its local watch container and cached display
  data.

Deleting local data does not delete information already held by OpenAI,
Anthropic, GitHub, Apple, or another service provider. Use that provider's
account and privacy controls for provider-held data.

## Tracking and Data Collection Declaration

- Tracking: **No**
- Data linked across apps or websites for advertising: **No**
- Data collected by the app maintainer: **None**
- Advertising or analytics SDKs: **None**

Direct requests to a provider for user-requested app functionality are not sent
to, retained by, or accessible to the maintainer.

## Security

AgentLimits uses platform security controls, HTTPS, account-scoped storage, and
bounded network responses. No software can guarantee absolute security. Keep
your devices updated, protect them with a passcode, grant credentials the least
privilege possible, and revoke a credential through its provider if you think
it may have been exposed.

## Changes and Contact

Material policy changes will update the effective date and policy version in
this file. For privacy questions or reports, open an issue in the
[AgentLimits Forked repository](https://github.com/JimBoHa/AgentLimits-forked/issues).
