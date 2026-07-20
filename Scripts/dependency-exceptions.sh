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
  [[ -x /usr/bin/ruby ]] \
    || dependency_exception_error "Ruby is required"
  command -v jq >/dev/null 2>&1 \
    || dependency_exception_error "jq is required"

  today="$(date -u +%F)"
  if ! allow_ghsas="$(
    /usr/bin/ruby --disable-gems -rjson -e '
      # JSON.parse normally keeps the last duplicate key. This map sees every
      # parsed pair and fails before canonical JSON can collapse either value.
      class UniqueJSONMap < Hash
        def []=(key, value)
          if key?(key)
            raise JSON::ParserError, "duplicate object key: #{key}"
          end
          super
        end
      end

      begin
        document = JSON.parse(
          File.binread(ARGV.fetch(0)),
          object_class: UniqueJSONMap,
          array_class: Array,
          create_additions: false,
          max_nesting: 32
        )
        STDOUT.write(JSON.generate(document))
      rescue JSON::JSONError, ArgumentError, SystemCallError => error
        warn "JSON preflight failed: #{error.message}"
        exit 78
      end
    ' "$registry" |
      jq -er --arg today "$today" '
    def nonempty_string:
      type == "string" and test("[^[:space:]]");
    def valid_date($minimum):
      . as $date
      | (type == "string")
        and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z")
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
        "\\AGHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}\\z"
      ))
      and .advisory_url == "https://github.com/advisories/\(.ghsa)"
      and (.tracking_issue | type == "string")
      and (.tracking_issue | test(
        "\\Ahttps://github\\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9._-]{0,99}/issues/[1-9][0-9]*\\z"
      ))
      and (.owner | type == "string")
      and (.owner | test(
        "\\A@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?(?:/[A-Za-z0-9][A-Za-z0-9_-]{0,99})?\\z"
      ))
      and (.affected_packages | type == "array" and length > 0)
      and (.affected_packages | all(
        .[];
        type == "string" and test(
          "\\Apkg:swift/github\\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9._-]{0,99}@(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?\\z"
        )
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

    if valid_registry($today) then
      [.exceptions[].ghsa] | join(",")
    else
      empty
    end
      '
  )"; then
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
  local diff_status=0
  local merge_base
  local registry_changed=false

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
  if ! merge_base="$(git merge-base --all "$base_sha" "$head_sha")"; then
    dependency_exception_error "base and head do not have a merge base"
  fi
  [[ "$merge_base" =~ ^[0-9a-f]{40}$ ]] \
    || dependency_exception_error "base and head need exactly one merge base"

  allow_ghsas="$(validate_dependency_exception_registry "$registry")"
  if git cat-file -e "$base_sha:$registry" 2>/dev/null; then
    base_has_registry=true
  fi
  diff_status=0
  git diff --quiet --no-ext-diff --no-textconv \
    "$merge_base" "$head_sha" -- "$registry" \
    || diff_status=$?
  case "$diff_status" in
    0) ;;
    1) registry_changed=true ;;
    *) dependency_exception_error "unable to compare dependency registry" ;;
  esac

  if [[ "$registry_changed" == true ]]; then
    if [[ "$base_has_registry" == true ]]; then
      diff_status=0
      git diff --quiet --no-ext-diff --no-textconv \
        "$merge_base" "$head_sha" -- \
        . ":(top,exclude,literal)$registry" \
        || diff_status=$?
      case "$diff_status" in
        0) ;;
        1)
          dependency_exception_error \
            "registry changes must be submitted in a registry-only pull request"
          ;;
        *) dependency_exception_error "unable to compare pull request paths" ;;
      esac
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
