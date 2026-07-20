# Release Checklist

## Source and version

- [ ] Working tree is clean and all intended PRs are merged.
- [ ] `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` match in macOS, widget,
      iOS, and Watch targets.
- [ ] The App Store Connect build number has not already been used.
- [ ] Dependencies are locked and their security advisories reviewed.
- [ ] `LICENSE` and complete Sparkle notices are present in source and product.
- [ ] Privacy policy, privacy manifests, App Store privacy answers, and review
      notes describe the shipping behavior.
- [ ] A source/API audit confirms every shipping required-reason API category
      and approved reason is represented accurately in each privacy manifest.
- [ ] No credentials, profiles, private keys, or local signing config are
      tracked by Git.

## Automated quality gates

- [ ] macOS unit/UI suite passes with warnings as errors.
- [ ] iPhone simulator unit/UI suite passes with warnings as errors.
- [ ] iPad simulator unit/UI suite passes with warnings as errors.
- [ ] Watch simulator unit/UI suite passes with warnings as errors.
- [ ] Static analysis passes for macOS and iOS/Watch Release graphs.
- [ ] Secret scan and dependency audit pass.
- [ ] Xcode product validation and fail-closed App Store product/privacy
      validation pass for the unsigned archive and final exported IPA.

## Device and behavior gates

- [ ] Fresh-install and upgrade smoke tests pass on supported macOS.
- [ ] Release-testing IPA installs on a physical iPhone and paired Apple Watch.
- [ ] Physical Watch receives sanitized account status and UUID-only refresh
      requests; no credential reaches the Watch.
- [ ] Multiple personal/work accounts stay isolated for every provider.
- [ ] GitHub Copilot exact session counts work; unsupported providers display
      unavailable rather than a fabricated zero.
- [ ] Account deletion, global clear, app reinstall, offline, stale-cache, and
      provider-error paths pass.

## macOS signing and notarization

- [ ] Archive records the intended Team and Developer ID Application identity.
- [ ] App and widget signatures verify strictly; hardened runtime is present.
- [ ] Every pinned Sparkle code object and architecture slice has the same Team,
      Developer ID trust, hardened runtime, secure timestamp, expected
      identifier, and no `get-task-allow`.
- [ ] Sparkle has exactly the audited nested-code and symlink inventory.
- [ ] App Group entitlement and provisioning profiles match the fork IDs.
- [ ] No executable has `get-task-allow`.
- [ ] App and widget are universal `arm64` + `x86_64`; dSYMs match UUIDs.
- [ ] PKG has a valid Developer ID Installer signature.
- [ ] DMG has a valid Developer ID Application signature from the same Team.
- [ ] Apple accepts app, PKG, and DMG notarization submissions.
- [ ] Every Apple notarization log matches its submission and has zero issues.
- [ ] Stapler validation and Gatekeeper app/package assessments pass.
- [ ] Final ZIP, expanded PKG, and read-only DMG reopen with exact layouts; each
      contained app matches both original Code Directory hashes and passes
      signature, stapler, and Gatekeeper checks.
- [ ] Expanded PKG installs only the app in `/Applications` and has no scripts.
- [ ] DMG integrity and clean-user quarantine installation pass.

## iOS, iPadOS, and watchOS distribution

- [ ] Archive records the intended Team and distribution profiles.
- [ ] Exported IPA signatures and embedded profiles match all bundle IDs.
- [ ] No executable has `get-task-allow`.
- [ ] iOS app is `arm64`; embedded Watch app is `arm64_32` + `arm64`.
- [ ] IPA includes both privacy manifests and the dependent Watch app.
- [ ] iOS/Watch version and build values match.
- [ ] Bundle IDs, version/build values, encryption declarations, launch/icon
      metadata, and Watch companion relationship match the audited contract.
- [ ] IPA contains only the audited iOS and Watch executable code objects; no
      unexpected framework, service, extension, bundle, library, or raw Mach-O.
- [ ] Both privacy manifests declare no tracking, no collected-data types, no
      tracking domains, and only UserDefaults reason `CA92.1`.
- [ ] Only the iOS companion scheme is archivable; the standalone Watch scheme
      remains non-archivable.
- [ ] Xcode/App Store validation passes without warning.
- [ ] TestFlight install and full smoke test pass.

## Store and publication

- [ ] Support and public privacy URLs work without authentication.
- [ ] Screenshots exist for required iPhone, iPad, and Watch sizes.
- [ ] App privacy, age rating, category, content rights, export compliance, and
      availability are complete in App Store Connect.
- [ ] App Review notes explain GitHub credential setup; any review credential
      is supplied only through App Store Connect.
- [ ] Release notes and checksums match the final artifacts.
- [ ] Exact commit is tagged only after every preceding gate passes.
- [ ] GitHub release contains notarized macOS artifacts and SHA-256 checksums.
- [ ] App Store release timing is explicitly selected after approval.
