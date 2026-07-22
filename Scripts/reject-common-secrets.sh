#!/bin/bash

set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [repository]" >&2
  exit 64
fi

repository="${1:-.}"
if ! git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Secret guard requires a Git worktree: $repository" >&2
  exit 69
fi

readonly secret_pattern='(gh[pousr]_[[:alnum:]]{20,}|github_pat_[[:alnum:]_]{20,}|-----BEGIN ((RSA|EC|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----)'

temporary_root="${RUNNER_TEMP:-/private/tmp}"
if [[ "$temporary_root" != /* || ! -d "$temporary_root" || -L "$temporary_root" ]]; then
  echo "Secret guard requires a trusted temporary directory." >&2
  exit 69
fi

match_list="$(mktemp "$temporary_root/AgentLimits-common-secrets.XXXXXX")"
chmod 600 "$match_list"
# shellcheck disable=SC2329  # Invoked indirectly by the EXIT trap below.
cleanup() {
  /bin/rm -f -- "$match_list"
}
trap cleanup EXIT

status=0
git -C "$repository" grep --cached -lzE "$secret_pattern" -- . > "$match_list" \
  || status=$?
case "$status" in
  0)
    while IFS= read -r -d '' path; do
      printf 'Possible secret in tracked path: %q\n' "$path" >&2
    done < "$match_list"
    echo 'Possible credential or private key committed to source.' >&2
    exit 78
    ;;
  1)
    exit 0
    ;;
  *)
    echo 'Secret guard could not inspect tracked source.' >&2
    exit 69
    ;;
esac
