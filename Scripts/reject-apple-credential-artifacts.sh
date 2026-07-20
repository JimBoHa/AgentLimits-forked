#!/bin/bash

set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [repository]" >&2
  exit 64
fi

repository="${1:-.}"
if ! git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Apple credential guard requires a Git worktree: $repository" >&2
  exit 69
fi

temporary_root="${RUNNER_TEMP:-/private/tmp}"
if [[ "$temporary_root" != /* || ! -d "$temporary_root" || -L "$temporary_root" ]]; then
  echo "Apple credential guard requires a trusted temporary directory." >&2
  exit 69
fi

list_file="$(
  mktemp "$temporary_root/AgentLimits-apple-credential-artifacts.XXXXXX"
)"
chmod 600 "$list_file"
cleanup() {
  /bin/rm -f -- "$list_file"
}
trap cleanup EXIT

git -C "$repository" ls-files -z -- \
  ':(icase,glob)**/*.p8' \
  ':(icase,glob)**/*.p12' \
  ':(icase,glob)**/*.pfx' \
  ':(icase,glob)**/*.pem' \
  ':(icase,glob)**/*.key' \
  ':(icase,glob)**/*.keychain' \
  ':(icase,glob)**/*.keychain-db' \
  ':(icase,glob)**/*.mobileprovision' \
  ':(icase,glob)**/*.provisionprofile' \
  ':(icase,glob)**/*.xcarchive/**' \
  > "$list_file"

found=false
while IFS= read -r -d '' path; do
  printf 'Tracked Apple credential artifact rejected: %q\n' "$path" >&2
  found=true
done < "$list_file"

if [[ "$found" == true ]]; then
  exit 78
fi
