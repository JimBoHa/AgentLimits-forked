# Apple Distribution

AgentLimits Forked has three Apple experiences but two distribution units:

- macOS: a Developer ID-signed, notarized app distributed as ZIP, DMG, or PKG.
- iOS and watchOS: one App Store/TestFlight IPA. The dependent Watch app is
  embedded in the iOS app and must never be exported as a separate installer.

The macOS app is intentionally unsandboxed because it runs local CLI tools and
manages LaunchAgents. Direct Developer ID distribution is supported. Mac App
Store distribution is not supported without a separate sandbox redesign.

## Required Apple account setup

1. Enroll the distributor in the Apple Developer Program.
2. Register these identifiers under one Team:
   - `com.jimboha.agentlimits.macos`
   - `com.jimboha.agentlimits.macos.widget`
   - `group.com.jimboha.agentlimits.macos`
   - `com.jimboha.agentlimits.ios`
   - `com.jimboha.agentlimits.ios.watchkitapp`
3. Enable the macOS App Group capability for the Mac app and widget.
4. Create or let Xcode manage distribution provisioning profiles for every
   signed executable. Developer ID profiles are required where Apple requires
   them for the App Group capability.
5. Install a Developer ID Application certificate and private key. Install a
   Developer ID Installer certificate and private key if shipping the PKG.
6. Create the iOS App Store Connect record. The Watch app belongs to that
   record as embedded content, not as another store listing.
7. In Xcode, sign in to the Apple account allowed to manage these identifiers.

Copy the local configuration template, then replace its example Team ID:

```sh
cp Configurations/DevelopmentTeam.local.xcconfig.example \
  Configurations/DevelopmentTeam.local.xcconfig
chmod 600 Configurations/DevelopmentTeam.local.xcconfig
chmod -N Configurations/DevelopmentTeam.local.xcconfig
```

The local file is gitignored and must remain Team-only. Signed release scripts
reject includes, conditional assignments, compiler flags, symlinks, ACLs, and
group/other-writable files. They build from a clean `git archive` snapshot with
a generated Team-only config, then record and recheck the local config hash.
They also replace inherited Xcode config/toolchain overrides and use the system
release-tool path before invoking Xcode.
Never commit certificates, private keys, provisioning profiles, App Store
Connect keys, passwords, or notarization credentials.

## Unsigned preflight artifacts

Use this only to prove the Release archive and installer layout before signing
material is available:

```sh
Scripts/build-unsigned-artifacts.sh /absolute/output/directory
```

The output includes unsigned macOS ZIP/DMG/PKG files and unsigned macOS and
iOS/watchOS archives. The builder requires a clean Git tree, builds from a
snapshot of the recorded commit, replaces inherited Xcode configuration and
toolchain overrides, and publishes through a temporary sibling directory only
after validation succeeds. The output parent must already exist, be owned by
the current user, and have no group/other write mode or ACL that grants mutation
access. A per-destination lock plus no-clobber rename prevents concurrent
builders from racing publication. The builder reopens every ZIP, DMG, and PKG
and compares the contained app or archive against a canonical file-tree
manifest.

`SHA256SUMS` covers every portable container, build log, metadata file, and the
two files in `ARCHIVE-MANIFESTS`. Those canonical manifests cover every regular
file, directory mode, and symlink in the unpacked `.xcarchive` directories. To
recheck an unpacked archive after copying it, regenerate its tree manifest with
`create_tree_manifest` from `Scripts/macos-container-validation.sh` and compare
the result byte-for-byte with the corresponding recorded manifest.

Here, “unsigned” means the first-party products have no Apple Team, certificate
identity, provisioning profile, installer signature, or DMG signature. Xcode's
linker still emits ad-hoc signatures for the native arm64 slices of the two
macOS Mach-O products; the builder requires those to be linker-generated,
Team-free, and free of sealed distribution resources. It requires the x86_64
slices to remain fully unsigned. Bundled third-party code may retain upstream
signatures.

These are non-distributable preflight artifacts. Do not re-sign or upload them.
A final release must be rebuilt by the signed workflows below so Xcode records
the Team, signing identity, and provisioning metadata.

## Signed iOS and watchOS export

For App Store Connect:

```sh
Scripts/export-ios.sh /absolute/output/directory app-store-connect
```

For registered-device testing:

```sh
Scripts/export-ios.sh /absolute/output/directory release-testing
```

Both commands archive the `AgentLimitsiOS` scheme. They verify that the signed
IPA contains `Watch/AgentLimitsWatch.app`, that identifiers and version numbers
match, and that distribution signatures do not contain `get-task-allow`.

After local verification, validate and upload through Xcode Organizer or App
Store Connect. TestFlight and a physical paired iPhone/Apple Watch smoke test
remain release gates; simulators cannot prove production WatchConnectivity.

## Signed and notarized macOS packages

Store notarization credentials in Keychain. The profile name is not secret;
the password must remain in Keychain:

```sh
xcrun notarytool store-credentials AgentLimitsForked-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

Enter the app-specific password only at the secure prompt; do not place it in
the command or shell history.

Then build, Developer ID-export, package, notarize, staple, and assess:

```sh
Scripts/package-macos.sh \
  /absolute/output/directory \
  AgentLimitsForked-notary \
  "Developer ID Installer: Legal Name (TEAMID)"
```

The workflow creates a universal app, ZIP, Developer ID Application-signed
DMG, and Developer ID Installer-signed PKG. It uses Xcode for Developer ID
export, `codesign` for the disk image, `productbuild` for the installer,
`notarytool` for notarization, and `stapler`/Gatekeeper assessment for final
verification. Every downloaded Apple notarization log must match its accepted
submission and contain no warnings or errors. Before notarization, the workflow
also verifies the exact pinned Sparkle code inventory, bundle metadata,
symlinks, same-Team Developer ID trust, hardened runtime, secure timestamps,
universal slices, and absence of `get-task-allow` independently in both
architectures. The workflow never performs an unsafe recursive ad-hoc re-sign.
It then reopens the final ZIP, expanded product PKG, and read-only DMG; rejects
unexpected layout or installer metadata; and rechecks the contained app's
per-slice Code Directory hashes, signatures, stapled ticket, and Gatekeeper
assessment before writing checksums.

## Release records

Keep the generated archive, build logs, notarization result/log files,
`BUILD-METADATA.txt`, and `SHA256SUMS` with the release. Complete
`RELEASE_CHECKLIST.md` before tagging. Publish only artifacts produced from the
exact tagged commit.
