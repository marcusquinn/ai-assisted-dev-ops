#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# =============================================================================
# CodeRabbit Collector Helper - PR Review Feedback into SQLite (t166.2)
# =============================================================================
# Polls for CodeRabbit review completion on PRs, extracts review comments
# and inline suggestions into a SQLite database, and categorises by severity.
#
# Usage:
#   coderabbit-collector-helper.sh collect [--pr NUMBER] [--wait]
#   coderabbit-collector-helper.sh poll --pr NUMBER [--timeout SECONDS]
#   coderabbit-collector-helper.sh query [--pr NUMBER] [--severity LEVEL] [--format json|text]
#   coderabbit-collector-helper.sh summary [--pr NUMBER] [--last N]
#   coderabbit-collector-helper.sh status
#   coderabbit-collector-helper.sh export [--format json|csv]
#   coderabbit-collector-helper.sh help
#
# Subtask: t166.2 - Structured feedback collection into SQLite
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC1091  # shared-constants path resolved at runtime
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

# =============================================================================
# Constants
# =============================================================================

readonly COLLECTOR_DATA_DIR="${HOME}/.aidevops/.agent-workspace/work/coderabbit-reviews"
readonly COLLECTOR_DB="${COLLECTOR_DATA_DIR}/reviews.db"
readonly CODERABBIT_BOT_LOGIN="coderabbitai"

# =============================================================================
# Logging: uses shared log_* from shared-constants.sh with COLLECTOR prefix
# =============================================================================
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="COLLECTOR"

# =============================================================================
# SQLite wrapper: sets busy_timeout on every connection (t135.3 pattern)
# =============================================================================

db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

# =============================================================================
# Database Initialization
# =============================================================================

ensure_db() {
	mkdir -p "$COLLECTOR_DATA_DIR" 2>/dev/null || true

	if [[ ! -f "$COLLECTOR_DB" ]]; then
		init_db
		return 0
	fi

	# Ensure WAL mode for existing databases
	local current_mode
	current_mode=$(db "$COLLECTOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$COLLECTOR_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || log_warn "Failed to enable WAL mode"
	fi

	return 0
}

init_db() {
	db "$COLLECTOR_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

-- PR review collection runs
CREATE TABLE IF NOT EXISTS collection_runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    repo        TEXT NOT NULL,
    pr_number   INTEGER NOT NULL,
    head_sha    TEXT,
    collected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    review_count INTEGER DEFAULT 0,
    comment_count INTEGER DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'complete'
);

-- CodeRabbit review-level entries (the top-level review body)
CREATE TABLE IF NOT EXISTS reviews (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER REFERENCES collection_runs(id),
    repo            TEXT NOT NULL,
    pr_number       INTEGER NOT NULL,
    gh_review_id    INTEGER UNIQUE,
    state           TEXT,
    body            TEXT,
    submitted_at    TEXT,
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- CodeRabbit inline/file-level comments
CREATE TABLE IF NOT EXISTS comments (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER REFERENCES collection_runs(id),
    repo            TEXT NOT NULL,
    pr_number       INTEGER NOT NULL,
    gh_comment_id   INTEGER UNIQUE,
    review_id       INTEGER REFERENCES reviews(id),
    path            TEXT,
    line            INTEGER,
    side            TEXT,
    body            TEXT NOT NULL,
    severity        TEXT NOT NULL DEFAULT 'info',
    category        TEXT DEFAULT 'general',
    created_at      TEXT,
    collected_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_comments_pr ON comments(repo, pr_number);
CREATE INDEX IF NOT EXISTS idx_comments_severity ON comments(severity);
CREATE INDEX IF NOT EXISTS idx_comments_category ON comments(category);
CREATE INDEX IF NOT EXISTS idx_comments_path ON comments(path);
CREATE INDEX IF NOT EXISTS idx_reviews_pr ON reviews(repo, pr_number);
CREATE INDEX IF NOT EXISTS idx_runs_pr ON collection_runs(repo, pr_number);
SQL

	log_info "Database initialized: $COLLECTOR_DB"
	return 0
}

# =============================================================================
# Repository Info
# =============================================================================

get_repo() {
	local repo
	repo="${GITHUB_REPOSITORY:-}"
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
			log_error "Not in a GitHub repository or gh CLI not configured"
			return 1
		}
	fi
	echo "$repo"
	return 0
}

get_pr_number() {
	local pr_number="${1:-}"
	if [[ -z "$pr_number" ]]; then
		pr_number=$(gh pr view --json number -q .number 2>/dev/null) || {
			log_error "No PR found for current branch. Specify with --pr NUMBER"
			return 1
		}
	fi
	echo "$pr_number"
	return 0
}

get_pr_head_sha() {
	local pr_number="$1"
	gh pr view "$pr_number" --json headRefOid -q .headRefOid 2>/dev/null || echo ""
	return 0
}

# =============================================================================
# Severity Classification
# =============================================================================

# Classify severity from a comment body
# Uses keyword matching for severity classification
classify_severity() {
	local body="$1"
	local lower_body
	lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

	if echo "$lower_body" | grep -qE "security|vulnerability|injection|credential|secret|xss|csrf|cve|exploit"; then
		echo "critical"
	elif echo "$lower_body" | grep -qE "bug|error|race.condition|memory.leak|null.pointer|crash|undefined|exception|panic"; then
		echo "high"
	elif echo "$lower_body" | grep -qE "performance|inefficient|unused|dead.code|complexity|deprecated|redundant|duplicate"; then
		echo "medium"
	elif echo "$lower_body" | grep -qE "style|naming|convention|formatting|documentation|typo|readability|nit"; then
		echo "low"
	else
		echo "info"
	fi
	return 0
}

# Classify category from a comment body
classify_category() {
	local body="$1"
	local lower_body
	lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

	if echo "$lower_body" | grep -qE "security|vulnerability|injection|credential|secret|auth"; then
		echo "security"
	elif echo "$lower_body" | grep -qE "bug|error|crash|exception|null|undefined|race"; then
		echo "bug"
	elif echo "$lower_body" | grep -qE "performance|slow|inefficient|optimize|cache|memory"; then
		echo "performance"
	elif echo "$lower_body" | grep -qE "style|naming|convention|format|lint|indent"; then
		echo "style"
	elif echo "$lower_body" | grep -qE "doc|comment|readme|description|jsdoc|typedoc"; then
		echo "documentation"
	elif echo "$lower_body" | grep -qE "test|coverage|assert|mock|spec|fixture"; then
		echo "testing"
	elif echo "$lower_body" | grep -qE "refactor|simplif|clean|extract|dedup|dry"; then
		echo "refactoring"
	elif echo "$lower_body" | grep -qE "type|interface|generic|cast|coercion"; then
		echo "type-safety"
	else
		echo "general"
	fi
	return 0
}

# =============================================================================
# Core: Poll for Review Completion
# =============================================================================

# Poll until CodeRabbit has posted a review on the PR
# Uses CI timing constants from shared-constants.sh
cmd_poll() {
	local pr_number=""
	local timeout="${CI_TIMEOUT_SLOW}"
	local interval="${CI_POLL_SLOW}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			pr_number="$2"
			shift 2
			;;
		--timeout)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --timeout"
				return 1
			}
			timeout="$2"
			shift 2
			;;
		--interval)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --interval"
				return 1
			}
			interval="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	pr_number=$(get_pr_number "$pr_number") || return 1
	local repo
	repo=$(get_repo) || return 1

	log_info "Polling for CodeRabbit review on PR #${pr_number} (timeout: ${timeout}s, interval: ${interval}s)"

	local elapsed=0
	local found=false

	while [[ $elapsed -lt $timeout ]]; do
		# Check for CodeRabbit reviews
		local review_count
		review_count=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
			--jq "[.[] | select(.user.login | contains(\"${CODERABBIT_BOT_LOGIN}\"))] | length" 2>/dev/null || echo "0")

		if [[ "$review_count" -gt 0 ]]; then
			log_success "CodeRabbit review found on PR #${pr_number} (${review_count} review(s), after ${elapsed}s)"
			found=true
			break
		fi

		# Also check for inline comments (CodeRabbit sometimes posts comments without a formal review)
		local comment_count
		comment_count=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
			--jq "[.[] | select(.user.login | contains(\"${CODERABBIT_BOT_LOGIN}\"))] | length" 2>/dev/null || echo "0")

		if [[ "$comment_count" -gt 0 ]]; then
			log_success "CodeRabbit comments found on PR #${pr_number} (${comment_count} comment(s), after ${elapsed}s)"
			found=true
			break
		fi

		echo -ne "\r  Waiting... ${elapsed}s / ${timeout}s (no review yet)"
		sleep "$interval"
		elapsed=$((elapsed + interval))
	done

	echo "" # Clear the progress line

	if [[ "$found" != "true" ]]; then
		log_warn "Timeout: No CodeRabbit review found after ${timeout}s on PR #${pr_number}"
		return 1
	fi

	return 0
}

# =============================================================================
# Core: Collect Reviews and Comments into SQLite
# =============================================================================

cmd_collect() {
	local pr_number=""
	local wait_for_review=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			pr_number="$2"
			shift 2
			;;
		--wait)
			wait_for_review=true
			shift
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	pr_number=$(get_pr_number "$pr_number") || return 1
	local repo
	repo=$(get_repo) || return 1

	ensure_db

	# Optionally wait for review to appear
	if [[ "$wait_for_review" == "true" ]]; then
		log_info "Waiting for CodeRabbit review before collecting..."
		if ! cmd_poll --pr "$pr_number"; then
			log_warn "Proceeding with collection despite timeout (may find partial results)"
		fi
	fi

	local head_sha
	head_sha=$(get_pr_head_sha "$pr_number")

	log_info "Collecting CodeRabbit feedback for ${repo} PR #${pr_number} (SHA: ${head_sha:0:8})"

	# Create collection run
	local run_id
	run_id=$(db "$COLLECTOR_DB" "
        INSERT INTO collection_runs (repo, pr_number, head_sha)
        VALUES ('$(sql_escape "$repo")', $pr_number, '$(sql_escape "$head_sha")');
        SELECT last_insert_rowid();
    ")

	# Collect reviews (top-level review bodies)
	local review_count=0
	review_count=$(collect_reviews "$repo" "$pr_number" "$run_id")

	# Collect inline comments
	local comment_count=0
	comment_count=$(collect_comments "$repo" "$pr_number" "$run_id")

	# Update run stats
	db "$COLLECTOR_DB" "
        UPDATE collection_runs
        SET review_count = $review_count, comment_count = $comment_count
        WHERE id = $run_id;
    "

	log_success "Collection complete: ${review_count} review(s), ${comment_count} comment(s)"
	log_info "Run ID: $run_id | DB: $COLLECTOR_DB"

	return 0
}

# Collect top-level reviews from CodeRabbit
# Uses jq to write a temp SQL file, avoiding shell expansion of $vars
# and backticks in review bodies.
collect_reviews() {
	local repo="$1"
	local pr_number="$2"
	local run_id="$3"

	local reviews_json
	reviews_json=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
		--jq "[.[] | select(.user.login | contains(\"${CODERABBIT_BOT_LOGIN}\"))]" 2>/dev/null || echo "[]")

	if [[ "$reviews_json" == "[]" || -z "$reviews_json" ]]; then
		echo "0"
		return 0
	fi

	# Use jq to generate SQL file with proper escaping.
	# jq's gsub handles single-quote doubling for SQL safety.
	# The jq filter file avoids shell quoting hell.
	local jq_filter_file sql_file
	jq_filter_file=$(mktemp)
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${jq_filter_file}'"
	push_cleanup "rm -f '${sql_file}'"

	cat >"$jq_filter_file" <<'JQ_EOF'
def sql_str: gsub("'"; "''") | "'" + . + "'";
.[] |
"INSERT OR IGNORE INTO reviews (run_id, repo, pr_number, gh_review_id, state, body, submitted_at) VALUES (" +
$run_id + ", " +
($repo | sql_str) + ", " +
($pr | tostring) + ", " +
(.id | tostring) + ", " +
((.state // "unknown") | sql_str) + ", " +
((.body // "") | sql_str) + ", " +
((.submitted_at // "") | sql_str) +
");"
JQ_EOF

	echo "$reviews_json" | jq -r \
		--arg run_id "$run_id" \
		--arg repo "$repo" \
		--argjson pr "$pr_number" \
		-f "$jq_filter_file" >"$sql_file"

	db "$COLLECTOR_DB" <"$sql_file" 2>/dev/null || log_warn "Some review inserts may have failed"

	local count
	count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM reviews WHERE run_id = $run_id;")
	rm -f "$sql_file" "$jq_filter_file"

	echo "$count"
	return 0
}

# Collect inline/file-level comments from CodeRabbit
# Severity and category are classified via jq keyword matching to avoid
# shell expansion issues with comment bodies containing $vars and backticks.
collect_comments() {
	local repo="$1"
	local pr_number="$2"
	local run_id="$3"

	local comments_json
	comments_json=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
		--jq "[.[] | select(.user.login | contains(\"${CODERABBIT_BOT_LOGIN}\"))]" 2>/dev/null || echo "[]")

	# Also collect issue-style comments (review summary posted as issue comment)
	local issue_comments_json
	issue_comments_json=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--jq "[.[] | select(.user.login | contains(\"${CODERABBIT_BOT_LOGIN}\"))]" 2>/dev/null || echo "[]")

	# Merge both arrays, marking issue comments with negative IDs
	local merged_json
	merged_json=$(printf '%s\n%s\n' "$comments_json" "$issue_comments_json" | jq -nc '
		input as $pr_comments |
		input as $issue_comments |
        [($pr_comments // [])[] | . + {"_source": "pr"}] +
        [($issue_comments // [])[] | . + {"_source": "issue", "id": (-.id), "path": "", "line": 0, "side": ""}]
    ')

	if [[ "$merged_json" == "[]" || -z "$merged_json" ]]; then
		echo "0"
		return 0
	fi

	# Generate SQL via jq with severity/category classification inline.
	# This avoids shell expansion of $vars and backticks in comment bodies.
	local jq_filter_file sql_file
	jq_filter_file=$(mktemp)
	sql_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${jq_filter_file}'"
	push_cleanup "rm -f '${sql_file}'"

	cat >"$jq_filter_file" <<'JQ_EOF'
def sql_str: gsub("'"; "''") | "'" + . + "'";
def classify_sev:
    ascii_downcase |
    if test("security|vulnerability|injection|credential|secret|xss|csrf|cve|exploit") then "critical"
    elif test("bug|error|race.condition|memory.leak|null.pointer|crash|undefined|exception|panic") then "high"
    elif test("performance|inefficient|unused|dead.code|complexity|deprecated|redundant|duplicate") then "medium"
    elif test("style|naming|convention|formatting|documentation|typo|readability|nit") then "low"
    else "info"
    end;
def classify_cat:
    ascii_downcase |
    if test("security|vulnerability|injection|credential|secret|auth") then "security"
    elif test("bug|error|crash|exception|null|undefined|race") then "bug"
    elif test("performance|slow|inefficient|optimize|cache|memory") then "performance"
    elif test("style|naming|convention|format|lint|indent") then "style"
    elif test("doc|comment|readme|description|jsdoc|typedoc") then "documentation"
    elif test("test|coverage|assert|mock|spec|fixture") then "testing"
    elif test("refactor|simplif|clean|extract|dedup|dry") then "refactoring"
    elif test("type|interface|generic|cast|coercion") then "type-safety"
    else "general"
    end;
.[] |
(.body // "") as $body |
"INSERT OR IGNORE INTO comments (run_id, repo, pr_number, gh_comment_id, path, line, side, body, severity, category, created_at) VALUES (" +
$run_id + ", " +
($repo | sql_str) + ", " +
($pr | tostring) + ", " +
(.id | tostring) + ", " +
((.path // "") | sql_str) + ", " +
((.line // .original_line // 0) | tostring) + ", " +
((.side // "RIGHT") | sql_str) + ", " +
($body | sql_str) + ", " +
($body | classify_sev | sql_str) + ", " +
($body | classify_cat | sql_str) + ", " +
((.created_at // "") | sql_str) +
");"
JQ_EOF

	echo "$merged_json" | jq -r \
		--arg run_id "$run_id" \
		--arg repo "$repo" \
		--argjson pr "$pr_number" \
		-f "$jq_filter_file" >"$sql_file"

	db "$COLLECTOR_DB" <"$sql_file" 2>/dev/null || log_warn "Some comment inserts may have failed"

	local count
	count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM comments WHERE run_id = $run_id;")
	rm -f "$sql_file" "$jq_filter_file"

	echo "$count"
	return 0
}

# =============================================================================
# SQL Escape Helper
# =============================================================================

# Escape a string for safe inclusion in SQLite single-quoted literals.
# Handles single quotes (doubled) and strips backslashes before quotes
# that cause tokenization errors.
sql_escape() {
	local val="$1"
	# Remove backslash-quote sequences that break SQLite tokenization
	val="${val//\\\'/\'}"
	val="${val//\\\"/\"}"
	# Double any remaining single quotes for SQL safety
	val="${val//\'/\'\'}"
	echo "$val"
	return 0
}

# =============================================================================
# Query Commands
# =============================================================================

# Build a SQL WHERE clause from optional pr_number, severity, and category filters.
# Outputs the WHERE clause string (empty string if no filters).
_query_build_where() {
	local pr_number="$1"
	local severity="$2"
	local category="$3"

	local where_clauses=()
	if [[ -n "$pr_number" ]]; then
		where_clauses+=("pr_number = $pr_number")
	fi
	if [[ -n "$severity" ]]; then
		where_clauses+=("severity = '$(sql_escape "$severity")'")
	fi
	if [[ -n "$category" ]]; then
		where_clauses+=("category = '$(sql_escape "$category")'")
	fi

	if [[ ${#where_clauses[@]} -eq 0 ]]; then
		echo ""
		return 0
	fi

	local where_sql="WHERE "
	local first=true
	local clause
	for clause in "${where_clauses[@]}"; do
		if [[ "$first" == "true" ]]; then
			where_sql="${where_sql}${clause}"
			first=false
		else
			where_sql="${where_sql} AND ${clause}"
		fi
	done
	echo "$where_sql"
	return 0
}

# Print query results in human-readable text format with colour-coded severity.
_query_print_text() {
	local pr_number="$1"
	local severity="$2"
	local category="$3"
	local where_sql="$4"
	local limit="$5"

	echo ""
	echo "CodeRabbit Review Comments"
	echo "=========================="
	[[ -n "$pr_number" ]] && echo "PR: #${pr_number}"
	[[ -n "$severity" ]] && echo "Severity: ${severity}"
	[[ -n "$category" ]] && echo "Category: ${category}"
	echo ""

	db "$COLLECTOR_DB" -separator $'\x1f' "
        SELECT severity, path, line,
               substr(replace(replace(body, char(10), ' '), char(13), ''), 1, 120)
        FROM comments
        $where_sql
        ORDER BY
            CASE severity
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END,
            created_at DESC
        LIMIT $limit;
    " | while IFS=$'\x1f' read -r sev path line body_preview; do
		local color="$NC"
		case "$sev" in
		critical | high) color="$RED" ;;
		medium) color="$YELLOW" ;;
		low) color="$BLUE" ;;
		esac

		local location="(review summary)"
		[[ -n "$path" ]] && location="${path}:${line}"

		echo -e "  ${color}[${sev}]${NC} ${location}"
		echo "    ${body_preview}"
		echo ""
	done

	local total
	total=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM comments $where_sql;")
	echo "Total: ${total} comment(s)"
	return 0
}

cmd_query() {
	local pr_number=""
	local severity=""
	local category=""
	local format="text"
	local limit=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			pr_number="$2"
			shift 2
			;;
		--severity)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --severity"
				return 1
			}
			severity="$2"
			shift 2
			;;
		--category)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --category"
				return 1
			}
			category="$2"
			shift 2
			;;
		--format)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --format"
				return 1
			}
			format="$2"
			shift 2
			;;
		--limit)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --limit"
				return 1
			}
			limit="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_db

	local where_sql
	where_sql=$(_query_build_where "$pr_number" "$severity" "$category")

	if [[ "$format" == "json" ]]; then
		db "$COLLECTOR_DB" -json "
            SELECT id, repo, pr_number, path, line, severity, category,
                   substr(body, 1, 500) as body_preview, created_at
            FROM comments
            $where_sql
            ORDER BY
                CASE severity
                    WHEN 'critical' THEN 1
                    WHEN 'high' THEN 2
                    WHEN 'medium' THEN 3
                    WHEN 'low' THEN 4
                    ELSE 5
                END,
                created_at DESC
            LIMIT $limit;
        "
	else
		_query_print_text "$pr_number" "$severity" "$category" "$where_sql" "$limit"
	fi

	return 0
}

# =============================================================================
# Summary Command
# =============================================================================

# Print severity breakdown table for the given WHERE clause.
_summary_print_severity() {
	local where_sql="$1"
	echo "Severity Breakdown:"
	db "$COLLECTOR_DB" -separator '|' "
        SELECT severity, COUNT(*) as cnt
        FROM comments
        $where_sql
        GROUP BY severity
        ORDER BY
            CASE severity
                WHEN 'critical' THEN 1
                WHEN 'high' THEN 2
                WHEN 'medium' THEN 3
                WHEN 'low' THEN 4
                ELSE 5
            END;
    " | while IFS='|' read -r sev cnt; do
		local color="$NC"
		case "$sev" in
		critical | high) color="$RED" ;;
		medium) color="$YELLOW" ;;
		low) color="$BLUE" ;;
		esac
		printf "  ${color}%-10s${NC} %s\n" "$sev" "$cnt"
	done
	return 0
}

# Print category breakdown table for the given WHERE clause.
_summary_print_categories() {
	local where_sql="$1"
	echo "Category Breakdown:"
	db "$COLLECTOR_DB" -separator '|' "
        SELECT category, COUNT(*) as cnt
        FROM comments
        $where_sql
        GROUP BY category
        ORDER BY cnt DESC;
    " | while IFS='|' read -r cat cnt; do
		printf "  %-15s %s\n" "$cat" "$cnt"
	done
	return 0
}

# Print the top 10 most-affected files for the given PR (or all PRs).
_summary_print_files() {
	local pr_number="$1"
	local files_where="WHERE path != ''"
	[[ -n "$pr_number" ]] && files_where="WHERE pr_number = $pr_number AND path != ''"
	echo "Most Affected Files:"
	db "$COLLECTOR_DB" -separator '|' "
        SELECT path, COUNT(*) as cnt,
               GROUP_CONCAT(DISTINCT severity) as severities
        FROM comments
        $files_where
        GROUP BY path
        ORDER BY cnt DESC
        LIMIT 10;
    " | while IFS='|' read -r path cnt severities; do
		printf "  %-50s %3s (%s)\n" "$path" "$cnt" "$severities"
	done
	return 0
}

# Print the most recent N collection runs.
_summary_print_runs() {
	local last_n="$1"
	echo "Recent Collection Runs (last $last_n):"
	db "$COLLECTOR_DB" -separator '|' "
        SELECT id, repo, pr_number, head_sha, collected_at, review_count, comment_count
        FROM collection_runs
        ORDER BY collected_at DESC
        LIMIT $last_n;
    " | while IFS='|' read -r run_id repo pr sha collected reviews comments; do
		echo "  Run #${run_id}: PR #${pr} (${sha:0:8}) - ${reviews} reviews, ${comments} comments [${collected}]"
	done
	return 0
}

cmd_summary() {
	local pr_number=""
	local last_n=5

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --pr"
				return 1
			}
			pr_number="$2"
			shift 2
			;;
		--last)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --last"
				return 1
			}
			last_n="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_db

	echo ""
	echo "CodeRabbit Review Summary"
	echo "========================="
	echo ""

	local where_sql=""
	[[ -n "$pr_number" ]] && where_sql="WHERE pr_number = $pr_number"

	_summary_print_severity "$where_sql"
	echo ""
	_summary_print_categories "$where_sql"
	echo ""
	_summary_print_files "$pr_number"
	echo ""
	_summary_print_runs "$last_n"
	echo ""
	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	ensure_db

	echo ""
	echo "CodeRabbit Collector Status"
	echo "==========================="
	echo ""

	# Check gh CLI
	if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		log_success "GitHub CLI: authenticated"
	else
		log_warn "GitHub CLI: not available or not authenticated"
	fi

	# Check jq
	if command -v jq &>/dev/null; then
		log_success "jq: installed"
	else
		log_warn "jq: not installed (required for JSON parsing)"
	fi

	# Database stats
	if [[ -f "$COLLECTOR_DB" ]]; then
		local run_count review_count comment_count
		run_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM collection_runs;" 2>/dev/null || echo "0")
		review_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM reviews;" 2>/dev/null || echo "0")
		comment_count=$(db "$COLLECTOR_DB" "SELECT COUNT(*) FROM comments;" 2>/dev/null || echo "0")

		echo ""
		echo "Database: $COLLECTOR_DB"
		echo "  Collection runs: $run_count"
		echo "  Reviews stored:  $review_count"
		echo "  Comments stored: $comment_count"

		# Last collection
		local last_run
		last_run=$(db "$COLLECTOR_DB" "SELECT collected_at || ' (PR #' || pr_number || ')' FROM collection_runs ORDER BY collected_at DESC LIMIT 1;" 2>/dev/null || echo "never")
		echo "  Last collection: $last_run"

		# DB file size
		local db_size
		db_size=$(_file_size_bytes "$COLLECTOR_DB")
		echo "  DB size: $((db_size / 1024)) KB"
	else
		echo ""
		echo "Database: not created yet"
		echo "  Run 'coderabbit-collector-helper.sh collect --pr NUMBER' to start"
	fi

	echo ""
	return 0
}

# =============================================================================
# Export Command
# =============================================================================

cmd_export() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			[[ -z "${2:-}" || "$2" == --* ]] && {
				log_error "Missing value for --format"
				return 1
			}
			format="$2"
			shift 2
			;;
		*)
			log_warn "Unknown option: $1"
			shift
			;;
		esac
	done

	ensure_db

	case "$format" in
	json)
		db "$COLLECTOR_DB" -json "
                SELECT c.id, c.repo, c.pr_number, c.path, c.line, c.side,
                       c.body, c.severity, c.category, c.created_at, c.collected_at,
                       r.head_sha
                FROM comments c
                LEFT JOIN collection_runs r ON c.run_id = r.id
                ORDER BY c.pr_number, c.severity, c.created_at;
            "
		;;
	csv)
		echo "id,repo,pr_number,path,line,severity,category,body_preview,created_at"
		db "$COLLECTOR_DB" -csv "
                SELECT c.id, c.repo, c.pr_number, c.path, c.line,
                       c.severity, c.category,
                       substr(replace(c.body, char(10), ' '), 1, 200),
                       c.created_at
                FROM comments c
                ORDER BY c.pr_number, c.severity, c.created_at;
            "
		;;
	*)
		log_error "Unknown format: $format (use json or csv)"
		return 1
		;;
	esac

	return 0
}

# =============================================================================
# Tasks Command - Archived (t1336)
# =============================================================================

cmd_tasks() {
	log_warn "coderabbit-task-creator-helper.sh has been archived (t1336)"
	log_info "AI reads CodeRabbit PR comments directly and creates better-scoped tasks."
	log_info "Use the pulse supervisor or /full-loop for task creation from findings."
	return 1
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP_EOF'
CodeRabbit Collector Helper - PR Review Feedback into SQLite (t166.2)

USAGE:
  coderabbit-collector-helper.sh <command> [options]

COMMANDS:
  collect     Collect CodeRabbit reviews and comments from a PR into SQLite
  poll        Poll until CodeRabbit posts a review on a PR
  query       Query stored comments with filters
  summary     Show severity/category breakdown and stats
  tasks       Create TODO tasks from collected findings (t166.3)
  status      Show collector status and database info
  export      Export all comments as JSON or CSV
  help        Show this help

COLLECT OPTIONS:
  --pr NUMBER     PR number (default: current branch's PR)
  --wait          Poll for review completion before collecting

POLL OPTIONS:
  --pr NUMBER     PR number (required)
  --timeout SECS  Max wait time (default: 600s)
  --interval SECS Poll interval (default: 30s)

QUERY OPTIONS:
  --pr NUMBER       Filter by PR number
  --severity LEVEL  Filter: critical, high, medium, low, info
  --category CAT    Filter: security, bug, performance, style, documentation,
                    testing, refactoring, type-safety, general
  --format FORMAT   Output: text (default), json
  --limit N         Max results (default: 50)

SUMMARY OPTIONS:
  --pr NUMBER     Filter by PR number
  --last N        Show last N collection runs (default: 5)

EXPORT OPTIONS:
  --format FORMAT   Output: json (default), csv

EXAMPLES:
  # Collect reviews from current PR
  coderabbit-collector-helper.sh collect

  # Wait for review then collect
  coderabbit-collector-helper.sh collect --pr 42 --wait

  # Poll for review completion
  coderabbit-collector-helper.sh poll --pr 42 --timeout 300

  # Query critical/high severity comments
  coderabbit-collector-helper.sh query --severity critical
  coderabbit-collector-helper.sh query --severity high --format json

  # Show summary breakdown
  coderabbit-collector-helper.sh summary --pr 42

  # Export all data
  coderabbit-collector-helper.sh export --format csv > reviews.csv

SEVERITY LEVELS:
  critical  - Security vulnerabilities, credential exposure
  high      - Bugs, race conditions, crashes, exceptions
  medium    - Performance, dead code, complexity, deprecated usage
  low       - Style, naming, conventions, typos
  info      - General suggestions, documentation

CATEGORIES:
  security, bug, performance, style, documentation,
  testing, refactoring, type-safety, general

DATABASE:
  SQLite database at: ~/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db
  Tables: collection_runs, reviews, comments
  Direct query: sqlite3 ~/.aidevops/.agent-workspace/work/coderabbit-reviews/reviews.db "SELECT ..."

HELP_EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	collect) cmd_collect "$@" ;;
	poll) cmd_poll "$@" ;;
	query) cmd_query "$@" ;;
	summary) cmd_summary "$@" ;;
	tasks) cmd_tasks "$@" ;;
	status) cmd_status "$@" ;;
	export) cmd_export "$@" ;;
	help | --help | -h) show_help ;;
	*)
		log_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
