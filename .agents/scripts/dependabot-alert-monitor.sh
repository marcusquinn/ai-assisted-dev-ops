#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dependabot-alert-monitor.sh - create worker-ready issues for grouped dependency alerts

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

DEPENDABOT_ALERT_MONITOR_STATE_DIR="${DEPENDABOT_ALERT_MONITOR_STATE_DIR:-${HOME}/.aidevops/cache/dependabot-alert-monitor}"
DEPENDABOT_ALERT_MONITOR_REPOS_JSON="${DEPENDABOT_ALERT_MONITOR_REPOS_JSON:-${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
DEPENDABOT_ALERT_MONITOR_MAX_REPOS="${DEPENDABOT_ALERT_MONITOR_MAX_REPOS:-50}"

_dam_log() {
  local message="$1"
  if [[ -n "${LOGFILE:-}" ]]; then
    printf '[dependabot-alert-monitor] %s\n' "$message" >>"$LOGFILE" 2>/dev/null || true
  else
    printf '[dependabot-alert-monitor] %s\n' "$message" >&2
  fi
  return 0
}

_dam_slug_key() {
  local repo_slug="$1"
  printf '%s\n' "$repo_slug" | tr '/:' '__'
  return 0
}

_dam_state_file_for_repo() {
  local repo_slug="$1"
  local slug_key=""
  slug_key="$(_dam_slug_key "$repo_slug")"
  printf '%s/%s.keys\n' "$DEPENDABOT_ALERT_MONITOR_STATE_DIR" "$slug_key"
  return 0
}

_dam_is_recently_seen() {
  local repo_slug="$1"
  local group_key="$2"
  local state_file=""
  state_file="$(_dam_state_file_for_repo "$repo_slug")"
  [[ -f "$state_file" ]] || return 1
  grep -Fxq -- "$group_key" "$state_file" 2>/dev/null
  return $?
}

_dam_record_seen() {
  local repo_slug="$1"
  local group_key="$2"
  local state_file=""
  state_file="$(_dam_state_file_for_repo "$repo_slug")"
  mkdir -p "$DEPENDABOT_ALERT_MONITOR_STATE_DIR" 2>/dev/null || return 0
  if ! _dam_is_recently_seen "$repo_slug" "$group_key"; then
    printf '%s\n' "$group_key" >>"$state_file" 2>/dev/null || true
  fi
  return 0
}

_dam_list_repos() {
  local repos_json="$1"
  [[ -f "$repos_json" ]] || return 1
  jq -r '
    .initialized_repos[]?
    | select(.maintenance != false)
    | select((.pulse // false) == true)
    | select((.local_only // false) == false)
    | select(.dependabot_alert_monitor != false)
    | select((.role // "maintainer") != "contributor")
    | select((.slug // "") != "")
    | [.slug, (.path // "")] | @tsv
  ' "$repos_json" 2>/dev/null
  return $?
}

_dam_fetch_alert_groups() {
  local repo_slug="$1"
  local alerts_json=""
  alerts_json=$(gh api --paginate --slurp "repos/${repo_slug}/dependabot/alerts?state=open&per_page=100" 2>/dev/null) || return 1
  printf '%s\n' "$alerts_json" | jq -r '
    [ .[][]?
      | select(.state == "open")
      | {
          package: (.dependency.package.name // "unknown"),
          ecosystem: (.dependency.package.ecystem // .dependency.package.ecosystem // "unknown"),
          manifest: (.dependency.manifest_path // "unknown"),
          severity: (.security_advisory.severity // "unknown"),
          patched: (.security_vulnerability.first_patched_version.identifier // "")
        }
    ]
    | sort_by(.package, .ecosystem, .patched)
    | group_by([.package, .ecosystem, .patched])[]?
    | {
        package: .[0].package,
        ecosystem: .[0].ecosystem,
        patched: .[0].patched,
        manifests: ([.[].manifest] | unique | join(", ")),
        severities: ([.[].severity] | unique | join(", ")),
        count: length
      }
    | [.package, .ecosystem, (if .patched == "" then "none" else .patched end), .manifests, .severities, (.count|tostring)] | @tsv
  ' 2>/dev/null
  return $?
}

_dam_issue_title() {
  local package_name="$1"
  local ecosystem="$2"
  local patched_version="$3"
  if [[ "$patched_version" == "none" || -z "$patched_version" ]]; then
    printf 'Investigate dependency alert: %s (%s)\n' "$package_name" "$ecosystem"
  else
    printf 'Remediate dependency alert: %s (%s)\n' "$package_name" "$ecosystem"
  fi
  return 0
}

_dam_issue_exists() {
  local repo_slug="$1"
  local title="$2"
  local issue_number=""
  issue_number=$(gh issue list --repo "$repo_slug" --state open --search "\"${title}\" in:title type:issue" --json number --limit 1 -q '.[0].number // ""' 2>/dev/null || true)
  [[ "$issue_number" =~ ^[1-9][0-9]*$ ]]
  return $?
}

_dam_ensure_labels() {
  local repo_slug="$1"
  shift
  local label=""
  for label in "$@"; do
    [[ -n "$label" ]] || continue
    gh label create "$label" --repo "$repo_slug" --color "EDEDED" --force >/dev/null 2>&1 || true
  done
  return 0
}

_dam_write_issue_body() {
  local body_file="$1"
  local package_name="$2"
  local ecosystem="$3"
  local patched_version="$4"
  local manifests="$5"
  local severities="$6"
  local alert_count="$7"

  {
    printf '## Summary\n\n'
    printf 'GitHub dependency alerts report %s open alert group(s) for %s%s%s in the %s%s%s ecosystem.\n\n' "$alert_count" '`' "$package_name" '`' '`' "$ecosystem" '`'
    printf '## Scope\n\n'
    printf '%s\n' "- Package: \`${package_name}\`"
    printf '%s\n' "- Ecosystem: \`${ecosystem}\`"
    printf '%s\n' "- Manifest path(s): \`${manifests}\`"
    printf '%s\n' "- Severity bucket(s): \`${severities}\`"
    if [[ "$patched_version" == "none" || -z "$patched_version" ]]; then
      printf '%s\n\n' '- Patched version: none reported by GitHub yet'
      printf '## How\n\n'
      printf 'Investigate whether the dependency can be removed, replaced, usage-constrained, or risk-accepted with a short code comment. Do not repeatedly file duplicate issues while GitHub reports no patched version.\n\n'
    else
      printf '%s\n\n' "- Minimum patched version reported by GitHub: \`${patched_version}\`"
      printf '## How\n\n'
      printf 'Update all affected manifest/lock files so the package resolves to at least the patched version, then run the relevant package-manager audit plus the repo quality gate.\n\n'
    fi
    printf '## Verification\n\n'
    printf '%s\n' '- Run the package-manager resolver/audit for the ecosystem.'
    printf '%s\n' '- Run the repo quality gate or the closest available focused tests.'
    printf '%s\n\n' '- Confirm GitHub dependency alerts close or reduce to no-patch follow-up alerts.'
    printf '## Privacy\n\n'
    printf 'This issue intentionally uses neutral dependency-remediation wording and omits advisory IDs, CVE details, exploit descriptions, and alert URLs.\n'
  } >"$body_file"
  return 0
}

_dam_create_issue_for_group() {
  local repo_slug="$1"
  local package_name="$2"
  local ecosystem="$3"
  local patched_version="$4"
  local manifests="$5"
  local severities="$6"
  local alert_count="$7"
  local dry_run="${8:-0}"
  local title=""
  local body_file=""
  local -a labels=()

  title="$(_dam_issue_title "$package_name" "$ecosystem" "$patched_version")"
  if _dam_issue_exists "$repo_slug" "$title"; then
    _dam_log "existing issue for ${repo_slug}: ${title}"
    return 0
  fi

  labels=("auto-dispatch" "origin:worker" "status:available" "tier:standard" "type:bug" "security")
  if [[ "$patched_version" == "none" || -z "$patched_version" ]]; then
    labels=("auto-dispatch" "origin:worker" "status:available" "tier:standard" "type:bug" "security" "needs-investigation")
  fi

  if [[ "$dry_run" == "1" ]]; then
    printf 'DRY_RUN repo=%s title=%s labels=%s\n' "$repo_slug" "$title" "${labels[*]}"
    return 0
  fi

  _dam_ensure_labels "$repo_slug" "${labels[@]}"
  body_file=$(mktemp "${TMPDIR:-/tmp}/dependabot-alert-issue.XXXXXX") || return 1
  _dam_write_issue_body "$body_file" "$package_name" "$ecosystem" "$patched_version" "$manifests" "$severities" "$alert_count"

  local -a create_args=(--repo "$repo_slug" --title "$title" --body-file "$body_file")
  local label=""
  for label in "${labels[@]}"; do
    create_args+=(--label "$label")
  done

  local issue_url=""
  issue_url=$(gh_create_issue "${create_args[@]}" 2>&1) || {
    rm -f "$body_file" 2>/dev/null || true
    _dam_log "failed to create issue in ${repo_slug}: ${title}: ${issue_url}"
    return 1
  }
  rm -f "$body_file" 2>/dev/null || true
  _dam_log "created issue for ${repo_slug}: ${title}"
  return 0
}

dependabot_alert_monitor_scan_repo() {
  local repo_slug="$1"
  local dry_run="${2:-0}"
  local groups=""
  local created=0
  local skipped=0
  local package_name ecosystem patched_version manifests severities alert_count group_key

  groups="$(_dam_fetch_alert_groups "$repo_slug")" || {
    _dam_log "unable to read Dependabot alerts for ${repo_slug}; skipping"
    return 0
  }

  while IFS=$'\t' read -r package_name ecosystem patched_version manifests severities alert_count; do
    [[ -n "$package_name" ]] || continue
    group_key="${package_name}|${ecosystem}|${patched_version}"
    if _dam_is_recently_seen "$repo_slug" "$group_key"; then
      if [[ "$patched_version" == "none" || -z "$patched_version" ]] || _dam_issue_exists "$repo_slug" "$(_dam_issue_title "$package_name" "$ecosystem" "$patched_version")"; then
        skipped=$((skipped + 1))
        continue
      fi
    fi
    if _dam_create_issue_for_group "$repo_slug" "$package_name" "$ecosystem" "$patched_version" "$manifests" "$severities" "$alert_count" "$dry_run"; then
      if [[ "$dry_run" != "1" ]]; then
        _dam_record_seen "$repo_slug" "$group_key"
      fi
      created=$((created + 1))
    fi
  done <<<"$groups"

  _dam_log "repo ${repo_slug}: created_or_confirmed=${created}, skipped=${skipped}"
  return 0
}

dependabot_alert_monitor_scan_repos() {
  local repos_json="${1:-$DEPENDABOT_ALERT_MONITOR_REPOS_JSON}"
  local dry_run="${2:-0}"
  local repo_count=0
  local repo_slug repo_path

  if [[ ! -f "$repos_json" ]]; then
    _dam_log "repos.json not found at ${repos_json}; skipping"
    return 0
  fi

  while IFS=$'\t' read -r repo_slug repo_path; do
    [[ -n "$repo_slug" ]] || continue
    repo_count=$((repo_count + 1))
    if [[ "$repo_count" -gt "$DEPENDABOT_ALERT_MONITOR_MAX_REPOS" ]]; then
      _dam_log "max repo limit reached (${DEPENDABOT_ALERT_MONITOR_MAX_REPOS}); skipping remainder"
      break
    fi
    dependabot_alert_monitor_scan_repo "$repo_slug" "$dry_run" || true
  done < <(_dam_list_repos "$repos_json" || true)

  _dam_log "scan complete across ${repo_count} managed repo(s)"
  return 0
}

main() {
  local command="${1:-scan}"
  local repos_json="$DEPENDABOT_ALERT_MONITOR_REPOS_JSON"
  local dry_run=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repos-json)
        repos_json="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  case "$command" in
    scan)
      dependabot_alert_monitor_scan_repos "$repos_json" "$dry_run"
      ;;
    *)
      printf 'Usage: dependabot-alert-monitor.sh scan [--repos-json PATH] [--dry-run]\n' >&2
      return 2
      ;;
  esac
  return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
