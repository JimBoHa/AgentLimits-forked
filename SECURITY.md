# Security Policy

## Supported Versions

Security fixes target the latest release and the current `main` branch.

## Confidential Vulnerability Reports

Do not disclose suspected vulnerabilities, credentials, tokens, or private data
in a public issue. Use GitHub's
[private vulnerability reporting form](https://github.com/JimBoHa/AgentLimits-forked/security/advisories/new).

Include affected version, reproduction steps, impact, and any suggested
mitigation. Remove real credentials and personal data from reproductions.

## Public Bugs

Report non-sensitive bugs through
[GitHub Issues](https://github.com/JimBoHa/AgentLimits-forked/issues).

## Dependency Security

Dependabot checks Swift Package Manager and GitHub Actions dependencies every
week. Across runtime, development, and unknown scopes, the dependency review
check fails when a pull request introduces a dependency with a known moderate,
high, or critical vulnerability. Make the `Block vulnerable dependency changes`
check required in the repository's branch rules to prevent a failed review from
being merged.

The dependency review workflow uses the read-only `pull_request` event. It does
not use `pull_request_target`, write permissions, repository secrets, or stored
checkout credentials, so it is safe to run for forked pull requests. The
exception-validation step executes the validator from the pull request's base
commit and treats the proposed registry as data. GitHub's dependency review API
must be available for the repository; public repositories are supported, while
private repositories require the applicable GitHub Advanced Security
entitlement.

An advisory may be suppressed only when it is a confirmed false positive or
when no safer version exists and the exposure has a documented compensating
control. Submit the suppression as a separate pull request that:

1. Changes only `.github/dependency-review-exceptions.json`.
2. Adds the advisory ID, canonical advisory URL, affected package URLs, tracking
   issue, justification, compensating controls, owner, and expiration date.
3. Uses an expiration date that has not passed. The date is inclusive and is
   evaluated in UTC.
4. Receives maintainer approval before merge.

Affected packages use the exact Swift package URL form
`pkg:swift/github.com/OWNER/REPOSITORY@SEMVER`; the required namespace contains
the package source host. Qualifiers, subpaths, non-GitHub sources, and
non-semantic versions are not supported.

The workflow validates every field, rejects duplicate or expired entries, and
derives `allow-ghsas` only from the registry. A new exception is not active in
the pull request that registers it; it can apply only after that registry-only
pull request is reviewed and merged. Direct `allow-ghsas` values in the
workflow are prohibited.

Remove the suppression as soon as a safe dependency version is available.
