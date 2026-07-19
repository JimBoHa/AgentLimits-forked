#!/bin/bash

# Fail-closed validation for JSON downloaded by `notarytool log`.

validate_accepted_notary_log() {
    local log="$1"
    local expected_job_id="$2"
    local issue_count

    if [[ ! -x /usr/bin/jq ]]; then
        echo "Apple jq is required to validate notarization logs" >&2
        return 69
    fi
    if [[ -L "$log" || ! -f "$log" ]]; then
        echo "Notarization log is missing or unsafe: $log" >&2
        return 1
    fi
    if ! /usr/bin/jq -e --arg job_id "$expected_job_id" '
        type == "object"
        and .jobId == $job_id
        and .status == "Accepted"
        and (.statusCode == 0 or .statusCode == "0")
        and has("issues")
        and (.issues == null or (.issues | type == "array"))
        and all(.issues[]?; type == "object")
    ' "$log" >/dev/null; then
        echo "Notarization log is malformed, mismatched, or not accepted" >&2
        return 1
    fi

    issue_count="$(/usr/bin/jq -r \
        'if .issues == null then 0 else (.issues | length) end' "$log")"
    if [[ ! "$issue_count" =~ ^[0-9]+$ || "$issue_count" != "0" ]]; then
        echo "Apple reported notarization issues:" >&2
        /usr/bin/jq -r '
            .issues[]
            | "[\(.severity // "unknown")] \(.path // "unknown path"): \(.message // "unspecified")"
        ' "$log" >&2
        return 1
    fi
}
