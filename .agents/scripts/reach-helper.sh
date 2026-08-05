#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# reach-helper.sh - Capability registry, doctor, and minimum-agency router.
#
# Thin orchestrator: cohesive implementation groups live in:
#   - reach-core-lib.sh     (shared JSON/path/hash/capability helpers)
#   - reach-broker-lib.sh   (capabilities, session/egress brokers, observations, failure classification)
#   - reach-route-lib.sh    (minimum-agency route decisions)
#   - reach-capture-lib.sh  (capture workflow and performance telemetry)
#   - reach-feedback-lib.sh (feedback mining and issue-body reporting)

set -euo pipefail

_script_path="${BASH_SOURCE[0]%/*}"
[[ "$_script_path" == "${BASH_SOURCE[0]}" ]] && _script_path="."
SCRIPT_DIR="$(cd "$_script_path" && pwd)" || exit 1
unset _script_path

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

if ! type log_error &>/dev/null; then
	log_error() {
		printf '[ERROR] %s\n' "$*" >&2
		return 0
	}
fi

readonly REACH_KEY_SCHEMA_VERSION="schema_version"
readonly REACH_KEY_BACKEND="backend"
readonly REACH_KEY_SENSITIVITY="sensitivity"
readonly REACH_KEY_TRUST="trust"
readonly REACH_VAL_UNVERIFIED="unverified"
readonly REACH_VAL_NONE="none"
readonly REACH_VAL_FETCH="fetch"
readonly REACH_VAL_AUTO="auto"
readonly REACH_VAL_FILE="file"
readonly REACH_VAL_UNAVAILABLE="unavailable"

usage() {
	cat <<'EOF'
Usage: reach-helper.sh <command> [options]

Commands:
  capabilities --format json
  doctor --format json
  network doctor --format json
  fingerprint doctor --format json
  profile lease|release|status [options] --format json
  cookie status|register|clear [options] --format json
  egress register|status|clear [options] --format json
  observation record --input <private-json> --format json
  classify-failure [--http-status <code>] [--has-login-wall true|false] [--has-captcha true|false] [--timeout true|false] [--selector-drift true|false] [--content-empty true|false] [--bot-block true|false] --format json
  route --objective <text> [--auth none|cookie|profile|manual] [--scope public|private] --format json
  watch --once --dry-run --format json
  capture --input <url-or-file> [--dest inbox|knowledge-inbox] [--method auto|file|fetch|crawl|browser] --format json
  feedback mine [--window 7d] [--format json|markdown]
  feedback issue [--dry-run] [--window 7d] [--format markdown|json]
  help

The helper does not contact arbitrary targets during registry, doctor, route,
profile, cookie, egress, or observation commands. Broker commands mutate only
private Reach metadata/evidence and never print queries, cookie values, proxy
credentials, credential-reference names, private paths, or raw targets.
EOF
	return 0
}

# shellcheck source=./reach-core-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-core-lib.sh"

# shellcheck source=./reach-broker-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-broker-lib.sh"

# shellcheck source=./reach-route-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-route-lib.sh"

# shellcheck source=./reach-capture-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-capture-lib.sh"

# shellcheck source=./reach-feedback-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-feedback-lib.sh"

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$command" in
		help | -h | --help)
			usage
			return 0
			;;
		capabilities)
			handle_capabilities "$@"
			return $?
			;;
		doctor)
			handle_doctor "$@"
			return $?
			;;
		network)
			handle_nested_doctor "network" "$@"
			return $?
			;;
		fingerprint)
			handle_nested_doctor "fingerprint" "$@"
			return $?
			;;
		profile)
			handle_profile "$@"
			return $?
			;;
		cookie)
			handle_cookie "$@"
			return $?
			;;
		egress)
			handle_egress "$@"
			return $?
			;;
		observation)
			handle_observation "$@"
			return $?
			;;
		classify-failure)
			handle_classify_failure "$@"
			return $?
			;;
		capture)
			handle_capture "$@"
			return $?
			;;
		feedback)
			handle_feedback "$@"
			return $?
			;;
		route)
			handle_route "$@"
			return $?
			;;
		watch)
			handle_watch "$@"
			return $?
			;;
		*)
			log_error "Unknown command: $command"
			usage >&2
			return 1
			;;
	esac
}

main "$@"
