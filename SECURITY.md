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
not use `pull_request_target`, write permissions, repository secrets, or a
checkout of contributor-controlled code, so it is safe to run for forked pull
requests. GitHub's dependency review API must be available for the repository;
public repositories are supported, while private repositories require the
applicable GitHub Advanced Security entitlement.

An advisory may be suppressed only when it is a confirmed false positive or
when no safer version exists and the exposure has a documented compensating
control. Submit the suppression as a separate pull request that:

1. Adds the advisory ID to an `allow-ghsas` input in
   `.github/workflows/dependency-review.yml`.
2. Links the upstream advisory and a tracking issue.
3. Documents affected versions, risk, compensating controls, owner, and an
   expiration or review date.
4. Receives maintainer approval before merge.

Remove the suppression as soon as a safe dependency version is available.
