#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# r-stub-title-scan.sh — Proactive detection: scan pulse-enabled repos for stub-title issues
#
# A stub title (e.g. "tNNN: $", "GH#NNN: $", ": $") is almost always the
# signature of the t2377 data-loss bug class or a similar framework misbehaviour.
# This scanner runs hourly and catches the incident BEFORE a human has to notice.
#
# Usage:
#   r-stub-title-scan.sh              Normal scan (files incident issues)
#   r-stub-title-scan.sh --dry-run    Scan and log only, no issue creation
#
# Environment:
#   STUB_SCAN_REPOS          Comma-separated slug allowlist (overrides repos.json)
#   STUB_SCAN_INCIDENT_REPO  Where to file incident issues (default: marcusquinn/aidevops)
#   STUB_SCAN_DRY_RUN=1      Equivalent to --dry-run flag
#
# State:
#   ~/.aidevops/logs/stub-title-incidents.log  — detection log (rotated at 1MB, 5 kept)
#   ~/.aidevops/cache/stub-title-seen.json     — 24h dedup cache
#
# Reference pattern: contribution-watch-helper.sh (cross-repo scan + file-issue-on-finding)
# Related: GH#19847 (t2377) — the data-loss bug this scanner detects instances of

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Resolve framework scripts directory (deployed or source)
FRAMEWORK_SCRIPTS="${HOME}/.aidevops/agents/scripts"
if [[ -f "${FRAMEWORK_SCRIPTS}/shared-constants.sh" ]]; then
    # shellcheck source=../../scripts/shared-constants.sh
    source "${FRAMEWORK_SCRIPTS}/shared-constants.sh" 2>/dev/null || true
fi

# Fallback colours when shared-constants.sh is not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${HOME}/.aidevops/logs/stub-title-incidents.log"
SEEN_CACHE="${HOME}/.aidevops/cache/stub-title-seen.json"
INCIDENT_REPO="${STUB_SCAN_INCIDENT_REPO:-marcusquinn/aidevops}"
DRY_RUN="${STUB_SCAN_DRY_RUN:-0}"
MAX_LOG_SIZE=1048576  # 1MB
LOG_RETENTION=5

# Parse flags
_parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1 ;;
            --help|-h)
                echo "Usage: r-stub-title-scan.sh [--dry-run]"
                echo "  Scan pulse-enabled repos to detect stub-title issues."
                echo "  --dry-run  Log findings only, do not create incident issues."
                exit 0
                ;;
            *)
                echo "Unknown argument: $arg" >&2
                exit 1
                ;;
        esac
    done
    return 0
}

# =============================================================================
# Helpers
# =============================================================================

_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[${ts}] [${level}] ${msg}" >> "$LOGFILE"
    # All console output goes to stderr so callers can capture function
    # return values via $(...) without log lines leaking into stdout.
    case "$level" in
        ERROR) echo -e "${RED}[${level}]${NC} ${msg}" >&2 ;;
        WARN)  echo -e "${YELLOW}[${level}]${NC} ${msg}" >&2 ;;
        *)     echo -e "${GREEN}[${level}]${NC} ${msg}" >&2 ;;
    esac
    return 0
}

_ensure_dirs() {
    mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$SEEN_CACHE")"
    return 0
}

# Rotate log when it exceeds MAX_LOG_SIZE. Keeps LOG_RETENTION rotated copies.
_rotate_log() {
    [[ -f "$LOGFILE" ]] || return 0
    local size
    size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
    size="${size// /}"  # trim whitespace (macOS wc quirk)
    (( size >= MAX_LOG_SIZE )) || return 0
    # Rotate: .5 -> delete, .4 -> .5, ... .1 -> .2, current -> .1
    local i prev
    for (( i = LOG_RETENTION; i >= 2; i-- )); do
        prev=$(( i - 1 ))
        [[ -f "${LOGFILE}.${prev}" ]] && mv "${LOGFILE}.${prev}" "${LOGFILE}.${i}"
    done
    mv "$LOGFILE" "${LOGFILE}.1"
    _log "INFO" "Log rotated (exceeded ${MAX_LOG_SIZE} bytes)"
    return 0
}

# Load the 24h dedup cache. Prune entries older than 24h.
_load_seen_cache() {
    [[ -f "$SEEN_CACHE" ]] || echo '{}' > "$SEEN_CACHE"
    local now cutoff pruned
    now=$(date +%s)
    cutoff=$(( now - 86400 ))
    pruned=$(jq --argjson cutoff "$cutoff" \
        'to_entries | map(select(.value >= $cutoff)) | from_entries' \
        "$SEEN_CACHE" 2>/dev/null) || pruned='{}'
    echo "$pruned" > "${SEEN_CACHE}.tmp" && mv "${SEEN_CACHE}.tmp" "$SEEN_CACHE" || {
        _log "ERROR" "Failed to write pruned cache to ${SEEN_CACHE}"
        return 1
    }
    return 0
}

# Check whether an issue+slug combo was already seen within 24h.
# Args: $1 = cache key (slug#number)
_is_seen() {
    local key="$1"
    local val
    val=$(jq -r --arg k "$key" '.[$k] // 0' "$SEEN_CACHE" 2>/dev/null) || val=0
    (( val > 0 ))
}

# Mark an issue+slug combo as seen now.
# Args: $1 = cache key (slug#number)
_mark_seen() {
    local key="$1"
    local now updated
    now=$(date +%s)
    updated=$(jq --arg k "$key" --argjson v "$now" '.[$k] = $v' "$SEEN_CACHE" 2>/dev/null) || {
        _log "WARN" "Failed to update seen cache for ${key}"
        return 1
    }
    echo "$updated" > "${SEEN_CACHE}.tmp" && mv "${SEEN_CACHE}.tmp" "$SEEN_CACHE" || {
        _log "ERROR" "Failed to write updated cache to ${SEEN_CACHE}"
        return 1
    }
    return 0
}

# Get list of pulse-enabled repo slugs (excluding local_only).
_get_pulse_repos() {
    [[ -n "${STUB_SCAN_REPOS:-}" ]] && { echo "$STUB_SCAN_REPOS" | tr ',' '\n'; return 0; }
    [[ -f "$REPOS_JSON" ]] || { _log "ERROR" "repos.json not found at ${REPOS_JSON}"; return 1; }
    jq -r '.initialized_repos[]? | select(.maintenance != false and .pulse == true) | select(.local_only != true) | .slug' \
        "$REPOS_JSON" || true
    return 0
}

# Build the incident issue body text. Kept as a function so the heredoc
# keywords do not inflate the awk-based nesting depth counter.
_build_incident_body() {
    local affected_slug="$1"
    local affected_number="$2"
    local stub_title="$3"
    local detect_ts
    detect_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    cat <<BODY
## Stub Title Detected

**Affected issue:** ${affected_slug}#${affected_number}
**Detected title:** \`${stub_title}\`
**Detection time:** ${detect_ts}
**Scanner:** \`r-stub-title-scan.sh\`

A stub title (\`tNNN:\`, \`GH#NNN:\`, or \`:\` followed by only whitespace) typically
indicates the t2377 data-loss bug class or similar framework misbehaviour where the
\`enrich-path\` overwrites the issue title/body with empty data.

### Recommended actions

1. Check the issue body — a wiped body confirms the enrich path fired with stale/empty data.
2. Restore the original title from \`git log\` of \`TODO.md\` or the task brief at \`todo/tasks/\`.
3. When this is a recurring pattern, investigate the dispatch that triggered the overwrite.

### Related

- GH#19847 (t2377) — root-cause data-loss bug
- \`.agents/reference/detection-routines.md\` — scanner documentation

<!-- aidevops:generator=r-stub-title-scan -->
BODY
    return 0
}

# File or update an incident issue on the incident repo.
# Args: $1 = affected slug, $2 = affected issue number, $3 = stub title
_file_incident_issue() {
    local affected_slug="$1"
    local affected_number="$2"
    local stub_title="$3"
    local incident_title="Incident: #${affected_number} has stub title in ${affected_slug}"

    [[ "$DRY_RUN" == "1" ]] && { _log "DRY-RUN" "Would file incident: ${incident_title}"; return 0; }

    # Check existing open incident to avoid duplicates
    local existing
    existing=$(gh issue list --repo "$INCIDENT_REPO" --state open \
        --search "Incident: #${affected_number} has stub title in ${affected_slug}" \
        --json number --jq '.[0].number // empty' 2>/dev/null) || existing=""

    [[ -n "$existing" ]] && { _update_existing_incident "$existing" "$affected_slug" "$affected_number" "$stub_title"; return $?; }

    _create_new_incident "$incident_title" "$affected_slug" "$affected_number" "$stub_title"
    return $?
}

# Update an existing incident issue with a timestamp comment.
# Args: $1 = existing issue number, $2 = slug, $3 = issue number, $4 = stub title
_update_existing_incident() {
    local existing="$1"
    local affected_slug="$2"
    local affected_number="$3"
    local stub_title="$4"
    local comment_body
    comment_body="Still observed at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Title: \`${stub_title}\`"
    gh issue comment "$existing" --repo "$INCIDENT_REPO" --body "$comment_body" >/dev/null 2>&1 || {
        _log "WARN" "Failed to comment on existing incident #${existing}"
        return 1
    }
    _log "INFO" "Updated existing incident #${existing} for ${affected_slug}#${affected_number}"
    return 0
}

# Create a new incident issue.
# Args: $1 = title, $2 = slug, $3 = issue number, $4 = stub title
_create_new_incident() {
    local incident_title="$1"
    local affected_slug="$2"
    local affected_number="$3"
    local stub_title="$4"
    local incident_body
    incident_body="$(_build_incident_body "$affected_slug" "$affected_number" "$stub_title")"

    local issue_url
    local create_cmd="gh issue create"
    type -t gh_create_issue >/dev/null 2>&1 && create_cmd="gh_create_issue"

    issue_url=$($create_cmd --repo "$INCIDENT_REPO" \
        --title "$incident_title" \
        --body "$incident_body" \
        --label "automation" --label "monitoring" --label "incident" 2>&1) || {
        _log "ERROR" "${create_cmd} failed for ${affected_slug}#${affected_number}: ${issue_url}"
        return 1
    }
    _log "INFO" "Filed incident issue: ${issue_url} for ${affected_slug}#${affected_number}"
    return 0
}

# Scan a single repo for stub-title issues.
# Args: $1 = slug
# Outputs found count to stdout. Returns 1 on fetch/parse failure.
_scan_single_repo() {
    local slug="$1"
    _log "INFO" "Scanning ${slug}..."

    local issues_json
    issues_json=$(gh issue list --repo "$slug" --state open --limit 500 \
        --json number,title 2>/dev/null) || {
        _log "WARN" "Failed to fetch issues for ${slug} (network/auth error)"
        return 1
    }

    local stubs
    stubs=$(echo "$issues_json" | jq -r '.[] | select(
        .title | test("^(t[0-9]+|GH#[0-9]+)?:\\s*$")
    ) | "\(.number)\t\(.title)"' 2>/dev/null) || {
        _log "WARN" "jq filter failed for ${slug}"
        return 1
    }

    [[ -z "$stubs" ]] && { _log "INFO" "No stub titles found in ${slug}"; echo 0; return 0; }

    local found=0
    local issue_num issue_title cache_key
    while IFS=$'\t' read -r issue_num issue_title; do
        [[ -z "$issue_num" ]] && continue
        found=$(( found + 1 ))
        cache_key="${slug}#${issue_num}"
        _log "FOUND" "Stub title in ${slug}#${issue_num}: '${issue_title}'"
        _is_seen "$cache_key" && _log "INFO" "Already reported ${cache_key} within 24h — updating existing incident"
        _file_incident_issue "$slug" "$issue_num" "$issue_title"
        _mark_seen "$cache_key"
    done <<< "$stubs"

    echo "$found"
    return 0
}

# =============================================================================
# Main scan
# =============================================================================

main() {
    _parse_args "$@"
    _ensure_dirs
    _rotate_log
    _load_seen_cache

    _log "INFO" "Stub-title scan started (dry_run=${DRY_RUN})"

    local repos
    repos=$(_get_pulse_repos) || { _log "ERROR" "Failed to enumerate pulse repos"; return 1; }

    local total_found=0 total_repos=0 failed_repos=0
    local slug repo_found

    while IFS= read -r slug; do
        [[ -z "$slug" ]] && continue
        total_repos=$(( total_repos + 1 ))
        repo_found=$(_scan_single_repo "$slug") || { failed_repos=$(( failed_repos + 1 )); continue; }
        total_found=$(( total_found + repo_found ))
    done <<< "$repos"

    _log "INFO" "Scan complete: ${total_repos} repos scanned, ${total_found} stub titles found, ${failed_repos} repos failed"
    (( total_found > 0 )) && _log "WARN" "Found ${total_found} stub-title issue(s) — check incident issues on ${INCIDENT_REPO}"

    return 0
}

main "$@"
