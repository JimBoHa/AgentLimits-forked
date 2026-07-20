#!/bin/bash

set -euo pipefail
PATH="/usr/bin:/bin"
export PATH

readonly dependency_exception_registry_path=".github/dependency-review-exceptions.json"

dependency_exception_error() {
  printf 'Dependency exception validation failed: %s\n' "$*" >&2
  exit 78
}

validate_dependency_exception_registry() {
  local registry="$1"
  local allow_ghsas
  local today

  [[ -f "$registry" && ! -L "$registry" ]] \
    || dependency_exception_error "registry must be a regular, non-symlink file"
  [[ "$(wc -c < "$registry" | tr -d '[:space:]')" -le 65536 ]] \
    || dependency_exception_error "registry exceeds 64 KiB"
  command -v jq >/dev/null 2>&1 \
    || dependency_exception_error "jq is required"

  today="$(date -u +%F)"
  if ! allow_ghsas="$(jq -er --slurp --arg today "$today" '
    def nonempty_string:
      type == "string" and test("[^[:space:]]");
    def valid_date($minimum):
      . as $date
      | (type == "string")
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        and (
          (try (
            $date + "T00:00:00Z"
            | fromdateiso8601
            | strftime("%Y-%m-%d")
          ) catch "") == $date
        )
        and $date >= $minimum;
    def valid_exception($minimum):
      type == "object"
      and keys == [
        "advisory_url",
        "affected_packages",
        "compensating_controls",
        "expires_on",
        "ghsa",
        "justification",
        "owner",
        "tracking_issue"
      ]
      and (.ghsa | type == "string")
      and (.ghsa | test(
        "^GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}$"
      ))
      and .advisory_url == "https://github.com/advisories/\(.ghsa)"
      and (.tracking_issue | type == "string")
      and (.tracking_issue | test(
        "^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$"
      ))
      and (.owner | type == "string")
      and (.owner | test(
        "^@[A-Za-z0-9][A-Za-z0-9-]{0,38}(/[A-Za-z0-9][A-Za-z0-9_-]{0,99})?$"
      ))
      and (.affected_packages | type == "array" and length > 0)
      and (.affected_packages | all(
        .[];
        type == "string" and test("^pkg:[a-z0-9.+-]+/.+")
      ))
      and (
        .affected_packages
        | length == (unique | length)
      )
      and (.justification | nonempty_string)
      and (.compensating_controls | nonempty_string)
      and (.expires_on | valid_date($minimum));

    def valid_registry($minimum):
      type == "object"
      and keys == ["exceptions", "schema_version"]
      and .schema_version == 1
      and (.exceptions | type == "array")
      and (.exceptions | all(.[]; valid_exception($minimum)))
      and (
        [.exceptions[].ghsa]
        | length == (unique | length)
      )
      and (
        [.exceptions[].ghsa]
        | . == sort
      );

    if length == 1 and (.[0] | valid_registry($today)) then
      .[0] | [.exceptions[].ghsa] | join(",")
    else
      empty
    end
  ' "$registry")"; then
    dependency_exception_error \
      "registry is malformed, duplicated, unsorted, or contains an expired record"
  fi

  printf '%s\n' "$allow_ghsas"
}

prepare_dependency_exceptions_for_pull_request() {
  local registry="$1"
  local base_sha="$2"
  local head_sha="$3"
  local github_output="$4"
  local repository_root
  local allow_ghsas
  local base_has_registry=false
  local registry_changed=false
  local -a changed_paths=()

  [[ "$registry" == "$dependency_exception_registry_path" ]] \
    || dependency_exception_error "unexpected registry path"
  [[ "$base_sha" =~ ^[0-9a-f]{40}$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
    || dependency_exception_error "base and head must be full commit IDs"
  [[ -f "$github_output" && ! -L "$github_output" ]] \
    || dependency_exception_error "GITHUB_OUTPUT must be a regular, non-symlink file"

  repository_root="$(git rev-parse --show-toplevel)"
  cd "$repository_root"
  git cat-file -e "$base_sha^{commit}" 2>/dev/null \
    || dependency_exception_error "base commit is unavailable"
  git cat-file -e "$head_sha^{commit}" 2>/dev/null \
    || dependency_exception_error "head commit is unavailable"

  allow_ghsas="$(validate_dependency_exception_registry "$registry")"
  if git cat-file -e "$base_sha:$registry" 2>/dev/null; then
    base_has_registry=true
  fi
  if ! git diff --quiet --no-ext-diff --no-textconv \
    "$base_sha" "$head_sha" -- "$registry"; then
    registry_changed=true
  fi

  if [[ "$registry_changed" == true ]]; then
    if [[ "$base_has_registry" == true ]]; then
      while IFS= read -r -d '' path; do
        changed_paths+=("$path")
      done < <(
        git diff --name-only -z --no-ext-diff --no-textconv \
          "$base_sha" "$head_sha"
      )
      [[ "${#changed_paths[@]}" -eq 1 \
        && "${changed_paths[0]}" == "$registry" ]] \
        || dependency_exception_error \
          "registry changes must be submitted in a registry-only pull request"
    elif [[ -n "$allow_ghsas" ]]; then
      dependency_exception_error \
        "bootstrap registry must not contain exceptions"
    fi

    # A new exception is never active in the pull request that registers it.
    # Registry-only pull requests have no dependency change to suppress.
    allow_ghsas=""
  fi

  [[ "$allow_ghsas" =~ ^(GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4})(,GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4})*$ \
    || -z "$allow_ghsas" ]] \
    || dependency_exception_error "validator produced an invalid advisory list"
  printf 'allow-ghsas=%s\n' "$allow_ghsas" >> "$github_output"
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  dependency-exceptions.sh validate REGISTRY' \
    '  dependency-exceptions.sh prepare-pull-request REGISTRY BASE_SHA HEAD_SHA GITHUB_OUTPUT' \
    >&2
  exit 64
}

[[ "$#" -ge 1 ]] || usage
case "$1" in
  validate)
    [[ "$#" -eq 2 ]] || usage
    validate_dependency_exception_registry "$2"
    ;;
  prepare-pull-request)
    [[ "$#" -eq 5 ]] || usage
    prepare_dependency_exceptions_for_pull_request "$2" "$3" "$4" "$5"
    ;;
  *)
    usage
    ;;
esac
