#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "$SCRIPT_DIR/shared-constants.sh"
fi
if [[ -f "$SCRIPT_DIR/pulse-runtime-pin.sh" ]]; then
	# shellcheck source=pulse-runtime-pin.sh
	source "$SCRIPT_DIR/pulse-runtime-pin.sh"
fi
# Read-only policy classifiers are sourced from each producer. Their apply
# functions are never called by this inventory helper.
# shellcheck source=setup/_backup.sh
source "$SCRIPT_DIR/setup/_backup.sh"
# shellcheck source=worker-failure-evidence.sh
source "$SCRIPT_DIR/worker-failure-evidence.sh"
OPENCODE_STORAGE_PROBES_AVAILABLE=0
if [[ -f "$SCRIPT_DIR/opencode-db-safety-lib.sh" ]]; then
	# shellcheck source=opencode-db-safety-lib.sh
	source "$SCRIPT_DIR/opencode-db-safety-lib.sh"
	OPENCODE_STORAGE_PROBES_AVAILABLE=1
fi

STORAGE_SCHEMA_VERSION=2
STORAGE_SIZE_TIMEOUT_TENTHS="${AIDEVOPS_STORAGE_SIZE_TIMEOUT_TENTHS:-20}"
STORAGE_DU_COMMAND="${AIDEVOPS_STORAGE_DU_COMMAND:-du}"
STORAGE_JSON_NULL=null
STORAGE_OWNER_FRAMEWORK=framework
STORAGE_SAFETY_MIXED=mixed
STORAGE_DISPOSITION_PROTECTED=protected
STORAGE_PRODUCER_PULSE=pulse-wrapper
STORAGE_UNKNOWN=unknown
STORAGE_PROTECTED="protected"
STORAGE_JOINT="joint"
STORAGE_ACTIVE="active"
STORAGE_ARCHIVE="archive"
STORAGE_PRODUCER_OPENCODE="opencode"

_storage_usage() {
	cat <<'USAGE'
Usage: storage-inventory-helper.sh [status|json|help]

Read-only inventory of explicitly registered aidevops-related stores.
It never deletes data and reports unavailable classifications as unknown.
USAGE
	return 0
}

_storage_measure_path() {
	local path="$1"
	local output_file=""
	local pid=""
	local elapsed=0
	local kib=""
	local ignored=""

	if [[ -z "$path" ]]; then
		printf 'null|unavailable|home-unavailable'
		return 0
	fi
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		printf '0|exact|missing'
		return 0
	fi
	if [[ -L "$path" ]]; then
		printf 'null|unavailable|root-is-symlink'
		return 0
	fi
	if [[ ! -r "$path" ]]; then
		printf 'null|unavailable|root-is-unreadable'
		return 0
	fi
	if ! command -v "$STORAGE_DU_COMMAND" >/dev/null 2>&1; then
		printf 'null|unavailable|sizing-command-unavailable'
		return 0
	fi

	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-storage-size.XXXXXX") || {
		printf 'null|unavailable|temporary-file-unavailable'
		return 0
	}
	LC_ALL=C "$STORAGE_DU_COMMAND" -sk "$path" >"$output_file" 2>/dev/null &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$STORAGE_SIZE_TIMEOUT_TENTHS" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file"
			printf 'null|unavailable|sizing-timeout'
			return 0
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	if ! wait "$pid"; then
		rm -f "$output_file"
		printf 'null|unavailable|sizing-failed'
		return 0
	fi
	IFS=$'\t ' read -r kib ignored <"$output_file" || kib=""
	rm -f "$output_file"
	case "$kib" in
	'' | *[!0-9]*) printf 'null|unavailable|invalid-size-output' ;;
	*) printf '%s|exact|' "$((kib * 1024))" ;;
	esac
	return 0
}

_storage_emit_measured_record() {
	local store_id="$1"
	local producer="$2"
	local display_path="$3"
	local owner="$4"
	local safety_class="$5"
	local policy="$6"
	local disposition="$7"
	local protection_reason="$8"
	local next_action="$9"
	local measured="${10}"
	local total_bytes="$STORAGE_JSON_NULL"
	local confidence="unavailable"
	local error=""
	local protected_bytes="$STORAGE_JSON_NULL"
	local reclaimable_bytes=0
	local unknown_bytes="$STORAGE_JSON_NULL"

	IFS='|' read -r total_bytes confidence error <<<"$measured"
	if [[ "$total_bytes" != "$STORAGE_JSON_NULL" ]]; then
		case "$disposition" in
		protected)
			protected_bytes="$total_bytes"
			unknown_bytes=0
			;;
		unknown)
			protected_bytes=0
			unknown_bytes="$total_bytes"
			;;
		*)
			protected_bytes=0
			unknown_bytes="$total_bytes"
			error="invalid-disposition"
			confidence="unavailable"
			;;
		esac
	fi

	jq -cn \
		--arg store_id "$store_id" \
		--arg producer "$producer" \
		--arg path "$display_path" \
		--arg owner "$owner" \
		--arg safety_class "$safety_class" \
		--arg policy "$policy" \
		--arg protection_reason "$protection_reason" \
		--arg confidence "$confidence" \
		--arg next_action "$next_action" \
		--arg error "$error" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson reclaimable_bytes "$reclaimable_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{store_id:$store_id,producer:$producer,path:$path,owner:$owner,safety_class:$safety_class,policy:$policy,total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:$reclaimable_bytes,unknown_bytes:$unknown_bytes,protection_reasons:[$protection_reason],sizing_confidence:$confidence,next_action:$next_action,error:(if $error == "" then null else $error end)}'
	return 0
}

_storage_emit_record() {
	local store_id="$1"
	local producer="$2"
	local display_path="$3"
	local actual_path="$4"
	local owner="$5"
	local safety_class="$6"
	local policy="$7"
	local disposition="$8"
	local protection_reason="$9"
	local next_action="${10:-}"
	local measured=""

	measured=$(_storage_measure_path "$actual_path")
	_storage_emit_measured_record "$store_id" "$producer" "$display_path" "$owner" \
		"$safety_class" "$policy" "$disposition" "$protection_reason" "$next_action" "$measured"
	return 0
}

_storage_measure_group() {
	local total_bytes=0
	local path=""
	local measured=""
	local path_bytes=""
	local confidence=""
	local error=""
	local saw_path=0

	for path in "$@"; do
		measured=$(_storage_measure_path "$path")
		IFS='|' read -r path_bytes confidence error <<<"$measured"
		if [[ "$path_bytes" == "null" ]]; then
			printf 'null|unavailable|%s' "${error:-component-unavailable}"
			return 0
		fi
		if [[ "$error" != "missing" ]]; then
			saw_path=1
		fi
		total_bytes=$((total_bytes + path_bytes))
	done
	if [[ "$saw_path" -eq 0 ]]; then
		printf '0|exact|missing'
	else
		printf '%s|exact|' "$total_bytes"
	fi
	return 0
}

_storage_opencode_residual_measurement() {
	local root_path="$1"
	shift
	local root_measure=""
	local root_bytes=""
	local root_confidence=""
	local root_error=""
	local known_bytes=0
	local component_path=""
	local component_measure=""
	local component_bytes=""
	local component_confidence=""
	local component_error=""

	root_measure=$(_storage_measure_path "$root_path")
	IFS='|' read -r root_bytes root_confidence root_error <<<"$root_measure"
	if [[ "$root_bytes" == "null" ]]; then
		printf 'null|unavailable|%s' "${root_error:-root-unavailable}"
		return 0
	fi
	for component_path in "$@"; do
		if [[ "$component_path" != "$root_path" && "$component_path" != "$root_path/"* ]]; then
			continue
		fi
		component_measure=$(_storage_measure_path "$component_path")
		IFS='|' read -r component_bytes component_confidence component_error <<<"$component_measure"
		if [[ "$component_bytes" == "null" ]]; then
			printf 'null|unavailable|known-component-unavailable'
			return 0
		fi
		known_bytes=$((known_bytes + component_bytes))
	done
	root_bytes=$((root_bytes - known_bytes))
	[[ "$root_bytes" -ge 0 ]] || root_bytes=0
	printf '%s|estimated|' "$root_bytes"
	return 0
}

_storage_emit_unavailable_opencode_records() {
	local unavailable_measure="${STORAGE_JSON_NULL}|unavailable|home-unavailable"
	local unavailable_reason="OpenCode data root is unavailable because HOME is unset"
	local unavailable_action="Set HOME or AIDEVOPS_OPENCODE_DATA_DIR to inventory OpenCode storage"
	local label_prefix=OpenCode

	_storage_emit_measured_record "opencode-active-db" "$STORAGE_PRODUCER_OPENCODE" "${label_prefix} active database" "$STORAGE_JOINT" \
		"$STORAGE_UNKNOWN" "logical session retention is OpenCode-owned" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	_storage_emit_measured_record "opencode-active-wal" "$STORAGE_PRODUCER_OPENCODE" "${label_prefix} active WAL/SHM" "$STORAGE_JOINT" \
		"$STORAGE_UNKNOWN" "checkpoint and VACUUM only after idle-holder evidence" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	_storage_emit_measured_record "opencode-archive" "aidevops-opencode-archive" "${label_prefix} archive database" "$STORAGE_JOINT" \
		"$STORAGE_UNKNOWN" "archive data is retained; no generic deletion contract" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	_storage_emit_measured_record "opencode-legacy" "$STORAGE_PRODUCER_OPENCODE" "${label_prefix} legacy storage" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "legacy format lifecycle is owned upstream" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	_storage_emit_measured_record "opencode-tool-output" "$STORAGE_PRODUCER_OPENCODE" "${label_prefix} tool output" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "tool-output lifecycle is owned upstream" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	_storage_emit_measured_record "opencode-unclassified" "$STORAGE_PRODUCER_OPENCODE" "Other ${label_prefix} application data" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "future and unclassified formats fail closed" "$STORAGE_UNKNOWN" "$unavailable_reason" "$unavailable_action" "$unavailable_measure"
	return 0
}

_storage_opencode_records() {
	local data_root="${AIDEVOPS_OPENCODE_DATA_DIR:-${HOME:+$HOME/.local/share/opencode}}"
	local active_db="${AIDEVOPS_OPENCODE_DB_PATH:-${OPENCODE_DB_PATH:-${OPENCODE_DB:-${data_root}/opencode.db}}}"
	local active_dir="${active_db%/*}"
	local archive_db=""
	local legacy_path="${data_root}/storage"
	local tool_path="${data_root}/tool"
	local active_measure=""
	local wal_measure=""
	local archive_measure=""
	local legacy_measure=""
	local tool_measure=""
	local residual_measure=""
	local active_schema="$STORAGE_UNKNOWN"
	local archive_schema="$STORAGE_UNKNOWN"
	local holder_count="$STORAGE_UNKNOWN"
	local wal_state="$STORAGE_UNKNOWN"
	local active_class="$STORAGE_ACTIVE"
	local active_disposition="$STORAGE_PROTECTED"
	local active_reason="OpenCode-owned logical sessions and live SQLite pages are never cleanup candidates"
	local archive_class="$STORAGE_ARCHIVE"
	local archive_disposition="$STORAGE_PROTECTED"
	local archive_reason="archive retention and integrity require explicit OpenCode-aware verification"
	local wal_reason="idle snapshot only; maintenance still requires holder and checkpoint evidence"

	if [[ -z "$data_root" ]]; then
		_storage_emit_unavailable_opencode_records
		return 0
	fi

	if [[ "$active_dir" == "$active_db" ]]; then
		active_dir="."
	fi
	archive_db="${AIDEVOPS_OPENCODE_ARCHIVE_DB:-${OPENCODE_ARCHIVE_DB:-${active_dir}/opencode-archive.db}}"
	active_measure=$(_storage_measure_group "$active_db")
	wal_measure=$(_storage_measure_group "${active_db}-wal" "${active_db}-shm")
	archive_measure=$(_storage_measure_group "$archive_db" "${archive_db}-wal" "${archive_db}-shm")
	legacy_measure=$(_storage_measure_group "$legacy_path")
	tool_measure=$(_storage_measure_group "$tool_path")
	residual_measure=$(_storage_opencode_residual_measurement "$data_root" \
		"$active_db" "${active_db}-wal" "${active_db}-shm" \
		"$archive_db" "${archive_db}-wal" "${archive_db}-shm" "$legacy_path" "$tool_path")

	if [[ "$OPENCODE_STORAGE_PROBES_AVAILABLE" -eq 1 ]]; then
		active_schema=$(opencode_db_schema_state "$active_db")
		archive_schema=$(opencode_db_schema_state "$archive_db")
		holder_count=$(opencode_db_holder_count "$active_db" "${AIDEVOPS_STORAGE_LSOF_COMMAND:-lsof}")
		wal_state=$(opencode_db_wal_state "$active_db" "${AIDEVOPS_STORAGE_WAL_SAMPLE_DELAY_SECONDS:-0.1}")
	fi
	if [[ "$active_schema" == "$STORAGE_UNKNOWN" ]]; then
		active_class="$STORAGE_UNKNOWN"
		active_disposition="$STORAGE_UNKNOWN"
		active_reason="active database schema is unavailable; all bytes remain unknown and untouched"
	fi
	if [[ "$archive_schema" == "$STORAGE_UNKNOWN" ]]; then
		archive_class="$STORAGE_UNKNOWN"
		archive_disposition="$STORAGE_UNKNOWN"
		archive_reason="archive schema is unavailable; all bytes remain unknown and untouched"
	fi
	if [[ "$holder_count" =~ ^[0-9]+$ && "$holder_count" -gt 0 ]]; then
		wal_reason="active database holder detected; WAL and shared-memory bytes are protected"
	elif [[ "$wal_state" == "changing" ]]; then
		wal_reason="WAL changed during observation; active SQLite state is protected"
	elif [[ "$holder_count" == "$STORAGE_UNKNOWN" || "$wal_state" == "$STORAGE_UNKNOWN" ]]; then
		wal_reason="holder or WAL state is unavailable; active SQLite bytes are protected"
	fi

	_storage_emit_measured_record "opencode-active-db" "$STORAGE_PRODUCER_OPENCODE" "OpenCode active database" "$STORAGE_JOINT" \
		"$active_class" "logical session retention is OpenCode-owned" "$active_disposition" "$active_reason" \
		"Use aidevops opencode-db report; do not select sessions by age or size" "$active_measure"
	_storage_emit_measured_record "opencode-active-wal" "$STORAGE_PRODUCER_OPENCODE" "OpenCode active WAL/SHM" "$STORAGE_JOINT" \
		"$STORAGE_ACTIVE" "checkpoint and VACUUM only after idle-holder evidence" "$STORAGE_PROTECTED" "$wal_reason" \
		"Close OpenCode holders, then use aidevops opencode-db maintain" "$wal_measure"
	_storage_emit_measured_record "opencode-archive" "aidevops-opencode-archive" "OpenCode archive database" "$STORAGE_JOINT" \
		"$archive_class" "archive data is retained; no generic deletion contract" "$archive_disposition" "$archive_reason" \
		"Inspect with aidevops opencode-db sessions --include-archive" "$archive_measure"
	_storage_emit_measured_record "opencode-legacy" "$STORAGE_PRODUCER_OPENCODE" "OpenCode legacy storage" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "legacy format lifecycle is owned upstream" "$STORAGE_UNKNOWN" "legacy format ownership or migration state is unproved" \
		"Use an upstream OpenCode migration/export path; leave data untouched" "$legacy_measure"
	_storage_emit_measured_record "opencode-tool-output" "$STORAGE_PRODUCER_OPENCODE" "OpenCode tool output" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "tool-output lifecycle is owned upstream" "$STORAGE_UNKNOWN" "tool output may be referenced by logical sessions" \
		"Use OpenCode-owned controls; no aidevops cleanup is available" "$tool_measure"
	_storage_emit_measured_record "opencode-unclassified" "$STORAGE_PRODUCER_OPENCODE" "Other OpenCode application data" "$STORAGE_UNKNOWN" \
		"$STORAGE_UNKNOWN" "future and unclassified formats fail closed" "$STORAGE_UNKNOWN" "unclassified OpenCode bytes have no proved mutation contract" \
		"Review with current OpenCode documentation and leave untouched" "$residual_measure"
	return 0
}

_storage_bundle_root_from_link() {
	local link_path="$1"
	local bundles_dir="$2"
	local agents_root=""
	local bundle_root=""
	local canonical_bundles=""
	[[ -L "$link_path" ]] || return 1
	agents_root=$(cd "$link_path" 2>/dev/null && pwd -P) || return 1
	bundle_root="${agents_root%/agents}"
	canonical_bundles=$(cd "$bundles_dir" 2>/dev/null && pwd -P) || return 1
	[[ "$agents_root" == "$bundle_root/agents" && "$bundle_root" == "$canonical_bundles/"* ]] || return 1
	printf '%s' "$bundle_root"
	return 0
}

_storage_bundle_lease_is_live() {
	local lease_dir="$1"
	local lease_file=""
	local lease_pid=""
	[[ -d "$lease_dir" ]] || return 1
	for lease_file in "$lease_dir"/*; do
		[[ -f "$lease_file" ]] || continue
		lease_pid="${lease_file##*/}"
		case "$lease_pid" in
		'' | *[!0-9]*) continue ;;
		esac
		# kill -0 can report EPERM for a live process owned by another user.
		if kill -0 "$lease_pid" 2>/dev/null || [[ -d "/proc/$lease_pid" ]] || ps -p "$lease_pid" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

_storage_resolve_pinned_runtime_bundle() {
	local pinned_agents_root=""
	local pin_rc=1
	[[ -n "${HOME:-}" ]] || return 1
	declare -F pulse_runtime_pin_resolve >/dev/null 2>&1 || return 1
	pinned_agents_root=$(pulse_runtime_pin_resolve 2>/dev/null) || pin_rc=$?
	case "$pin_rc" in
	0)
		printf '%s\n' "${pinned_agents_root%/agents}"
		return 0
		;;
	1 | 3) return 1 ;;
	*) return 2 ;;
	esac
	return 1
}

_storage_emit_runtime_bundle_record() {
	local bundles_dir="${HOME:+$HOME/.aidevops/runtime-bundles}"
	local measured=""
	local total_bytes="null"
	local confidence="unavailable"
	local error=""
	local protected_bytes=0
	local reclaimable_bytes=0
	local unknown_bytes="null"
	local active_bundle=""
	local previous_bundle=""
	local pinned_bundle=""
	local pin_rc=1
	local protected_list=$'\n'
	local lease_dir=""
	local leased_bundle=""
	local bundle_root=""
	local bundle_measure=""
	local bundle_bytes=""
	local bundle_confidence=""
	local bundle_error=""

	measured=$(_storage_measure_path "$bundles_dir")
	IFS='|' read -r total_bytes confidence error <<<"$measured"
	pinned_bundle=$(_storage_resolve_pinned_runtime_bundle) || pin_rc=$?
	[[ "$pin_rc" -ne 2 ]] || error="pulse-pin-reference-invalid"
	if [[ "$total_bytes" == "0" ]]; then
		unknown_bytes=0
	elif [[ "$total_bytes" != "null" ]]; then
		if ! active_bundle=$(_storage_bundle_root_from_link "${HOME}/.aidevops/agents" "$bundles_dir"); then
			error="active-reference-unavailable"
			unknown_bytes="$total_bytes"
		else
			protected_list+="${active_bundle}"$'\n'
			if [[ -n "$pinned_bundle" ]]; then
				[[ "$protected_list" == *$'\n'"${pinned_bundle}"$'\n'* ]] || protected_list+="${pinned_bundle}"$'\n'
			fi
			if [[ -L "${HOME}/.aidevops/previous-runtime-bundle" ]]; then
				if previous_bundle=$(_storage_bundle_root_from_link "${HOME}/.aidevops/previous-runtime-bundle" "$bundles_dir"); then
					[[ "$protected_list" == *$'\n'"${previous_bundle}"$'\n'* ]] || protected_list+="${previous_bundle}"$'\n'
				else
					error="previous-reference-unavailable"
				fi
			fi
			for lease_dir in "$bundles_dir/.leases"/*; do
				[[ -d "$lease_dir" ]] || continue
				_storage_bundle_lease_is_live "$lease_dir" || continue
				leased_bundle="$bundles_dir/${lease_dir##*/}"
				[[ -d "$leased_bundle/agents" ]] || {
					error="live-lease-target-unavailable"
					continue
				}
				[[ "$protected_list" == *$'\n'"${leased_bundle}"$'\n'* ]] || protected_list+="${leased_bundle}"$'\n'
			done
			if [[ -z "$error" ]]; then
				while IFS= read -r bundle_root; do
					[[ -n "$bundle_root" ]] || continue
					bundle_measure=$(_storage_measure_path "$bundle_root")
					IFS='|' read -r bundle_bytes bundle_confidence bundle_error <<<"$bundle_measure"
					if [[ "$bundle_bytes" == "null" ]]; then
						error="protected-size-unavailable"
						break
					fi
					protected_bytes=$((protected_bytes + bundle_bytes))
				done <<<"$protected_list"
			fi
			if [[ -z "$error" ]]; then
				bundle_measure=$(_storage_measure_path "$bundles_dir/.leases")
				IFS='|' read -r bundle_bytes bundle_confidence bundle_error <<<"$bundle_measure"
				if [[ "$bundle_bytes" == "null" ]]; then
					error="lease-metadata-size-unavailable"
				else
					protected_bytes=$((protected_bytes + bundle_bytes))
				fi
			fi
			if [[ -z "$error" ]]; then
				[[ "$protected_bytes" -le "$total_bytes" ]] || protected_bytes="$total_bytes"
				reclaimable_bytes=$((total_bytes - protected_bytes))
				unknown_bytes=0
			else
				protected_bytes=0
				reclaimable_bytes=0
				unknown_bytes="$total_bytes"
				confidence="unavailable"
			fi
		fi
	fi

	jq -cn \
		--arg owner "$STORAGE_OWNER_FRAMEWORK" \
		--arg safety_class "$STORAGE_SAFETY_MIXED" \
		--arg error "$error" \
		--arg confidence "$confidence" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson reclaimable_bytes "$reclaimable_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{store_id:"runtime-bundles",producer:"agent-deploy",path:"~/.aidevops/runtime-bundles",owner:$owner,safety_class:$safety_class,policy:"30-day age, 30-bundle count, and 8 GiB soft limits; references, an active Pulse runtime pin, and live leases veto deletion",total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:$reclaimable_bytes,unknown_bytes:$unknown_bytes,protection_reasons:["current bundle, previous rollback bundle, active Pulse runtime pin, live leases, and lease metadata"],sizing_confidence:$confidence,next_action:"Use setup activation for policy-owned pruning; do not delete protected bundles manually",error:(if $error == "" or $error == "missing" then null else $error end)}'
	return 0
}

_storage_plan_reclaimable_bytes() {
	local plan="$1"
	local candidate_path=""
	local candidate_bytes=""
	local candidate_reason=""
	local reclaimable_bytes=0
	while IFS=$'\t' read -r candidate_path candidate_bytes candidate_reason; do
		[[ -n "$candidate_path" ]] || continue
		case "$candidate_bytes" in
		'' | *[!0-9]*) return 1 ;;
		esac
		[[ -n "$candidate_reason" ]] || return 1
		reclaimable_bytes=$((reclaimable_bytes + candidate_bytes))
	done <<<"$plan"
	printf '%s' "$reclaimable_bytes"
	return 0
}

_storage_worker_excerpt_plan() {
	local excerpt_dir="$1"
	local excerpt_path=""
	local excerpt_name=""
	local safe_key=""
	local known_keys=$'\n'
	local plan=""
	[[ -d "$excerpt_dir" && ! -L "$excerpt_dir" ]] || return 0
	for excerpt_path in "$excerpt_dir"/*; do
		[[ -e "$excerpt_path" || -L "$excerpt_path" ]] || continue
		excerpt_name="${excerpt_path##*/}"
		[[ "$excerpt_name" == ".retention-trash" && -d "$excerpt_path" && ! -L "$excerpt_path" ]] && continue
		[[ -f "$excerpt_path" && ! -L "$excerpt_path" ]] || return 2
		if [[ "$excerpt_name" =~ ^(.+)-[0-9]{8}T[0-9]{6}Z-[0-9]+\.log$ ]]; then
			safe_key="${BASH_REMATCH[1]}"
		else
			return 2
		fi
		[[ "$safe_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
		[[ "$known_keys" == *$'\n'"${safe_key}"$'\n'* ]] || known_keys+="${safe_key}"$'\n'
	done
	while IFS= read -r safe_key; do
		[[ -n "$safe_key" ]] || continue
		plan=$(_worker_excerpt_retention_plan "$excerpt_dir" "$safe_key") || return 2
		[[ -n "$plan" ]] && printf '%s\n' "$plan"
	done <<<"$known_keys"
	return 0
}

_storage_emit_retention_record() {
	local store_id="$1"
	local producer="$2"
	local display_path="$3"
	local actual_path="$4"
	local safety_class="$5"
	local policy="$6"
	local protection_reason="$7"
	local next_action="$8"
	local classifier="$9"
	local measured=""
	local total_bytes="$STORAGE_JSON_NULL"
	local confidence="unavailable"
	local error=""
	local plan=""
	local reclaimable_bytes=0
	local protected_bytes="$STORAGE_JSON_NULL"
	local unknown_bytes="$STORAGE_JSON_NULL"

	measured=$(_storage_measure_path "$actual_path")
	IFS='|' read -r total_bytes confidence error <<<"$measured"
	if [[ "$total_bytes" != "$STORAGE_JSON_NULL" ]]; then
		if [[ "$total_bytes" == "0" ]]; then
			protected_bytes=0
			unknown_bytes=0
		elif ! plan=$($classifier "$actual_path"); then
			protected_bytes=0
			reclaimable_bytes=0
			unknown_bytes="$total_bytes"
			error="classification-unavailable"
			confidence="unavailable"
		elif ! reclaimable_bytes=$(_storage_plan_reclaimable_bytes "$plan"); then
			protected_bytes=0
			reclaimable_bytes=0
			unknown_bytes="$total_bytes"
			error="invalid-retention-plan"
			confidence="unavailable"
		elif [[ "$reclaimable_bytes" -gt "$total_bytes" ]]; then
			protected_bytes=0
			reclaimable_bytes=0
			unknown_bytes="$total_bytes"
			error="candidate-bytes-exceed-total"
			confidence="unavailable"
		else
			protected_bytes=$((total_bytes - reclaimable_bytes))
			unknown_bytes=0
		fi
	fi

	jq -cn \
		--arg store_id "$store_id" \
		--arg producer "$producer" \
		--arg path "$display_path" \
		--arg safety_class "$safety_class" \
		--arg policy "$policy" \
		--arg protection_reason "$protection_reason" \
		--arg confidence "$confidence" \
		--arg next_action "$next_action" \
		--arg owner "$STORAGE_OWNER_FRAMEWORK" \
		--arg error "$error" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson reclaimable_bytes "$reclaimable_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{store_id:$store_id,producer:$producer,path:$path,owner:$owner,safety_class:$safety_class,policy:$policy,total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:$reclaimable_bytes,unknown_bytes:$unknown_bytes,protection_reasons:[$protection_reason],sizing_confidence:$confidence,next_action:$next_action,error:(if $error == "" or $error == "missing" then null else $error end)}'
	return 0
}

_storage_observability_record() {
	local home_label="~"
	local display_path="${home_label}/.aidevops/.agent-workspace/observability"
	local actual_path="${HOME:+$HOME/.aidevops/.agent-workspace/observability}"
	local report=""
	local measured=""
	local total_bytes="$STORAGE_JSON_NULL"
	local confidence="unavailable"
	local sizing_error=""

	report=$(bash "$SCRIPT_DIR/observability-helper.sh" storage --json 2>/dev/null || true)
	if [[ -z "$report" ]] || ! printf '%s\n' "$report" | jq -e '
		def is_number: type == "number";
		type == "object" and (.active_bytes | is_number) and
		(.archive_bytes | is_number) and (.protected_bytes | is_number) and
		(.reclaimable_bytes | is_number) and (.unknown_bytes | is_number)
	' >/dev/null 2>&1; then
		_storage_emit_record "observability" "opencode-aidevops" "$display_path" "$actual_path" \
			"$STORAGE_OWNER_FRAMEWORK" "$STORAGE_UNKNOWN" "retention inventory unavailable" "$STORAGE_UNKNOWN" \
			"classification unavailable" "Use observability-helper.sh storage --json" |
			jq -c '.error = (if .error == "home-unavailable" then .error else "retention-inventory-unavailable" end)'
		return 0
	fi

	measured=$(_storage_measure_path "$actual_path")
	IFS='|' read -r total_bytes confidence sizing_error <<<"$measured"
	jq -cn \
		--arg path "$display_path" \
		--arg owner "$STORAGE_OWNER_FRAMEWORK" \
		--arg confidence "$confidence" \
		--arg sizing_error "$sizing_error" \
		--argjson total_bytes "$total_bytes" \
		--argjson retention "$report" '
		($retention.protected_bytes | if $total_bytes == null then null elif . > $total_bytes then $total_bytes else . end) as $protected |
		(if $total_bytes == null then null else ($total_bytes - ($protected // 0)) end) as $unknown |
		{store_id:"observability",producer:"opencode-aidevops",path:$path,owner:$owner,safety_class:"audit",
		 policy:$retention.policy,total_bytes:$total_bytes,active_bytes:$retention.active_bytes,
		 archive_bytes:$retention.archive_bytes,candidate_bytes:$retention.candidate_bytes,
		 protected_bytes:$protected,reclaimable_bytes:0,unknown_bytes:$unknown,
		 protection_reasons:["verified archives and pinned state-recovery evidence"],
		 sizing_confidence:(if $sizing_error == "" and $retention.error == null then "estimated" else "unavailable" end),
		 next_action:$retention.next_action,
		 error:(if $sizing_error != "" then $sizing_error else $retention.error end)}'
	return 0
}

_storage_inventory_records() {
	local home_label="~"
	local framework_owner="$STORAGE_OWNER_FRAMEWORK"
	local active_class="active"
	local active_writer_reason="active concurrent writer"
	local protected_disposition="$STORAGE_DISPOSITION_PROTECTED"
	local pulse_producer="$STORAGE_PRODUCER_PULSE"
	_storage_emit_runtime_bundle_record
	_storage_observability_record
	_storage_emit_retention_record "agent-backups" "setup-backup" "${home_label}/.aidevops/agents-backups" "${HOME:+$HOME/.aidevops/agents-backups}" "$STORAGE_SAFETY_MIXED" "10 snapshots, 180 days, and 4 GiB soft limits" "newest verified rollback and retention trash" "Setup computes a dry run before confirmed producer-owned rotation" "_backup_retention_plan"
	_storage_emit_retention_record "worker-failure-excerpts" "headless-runtime" "${home_label}/.aidevops/logs/worker-failure-excerpts" "${HOME:+$HOME/.aidevops/logs/worker-failure-excerpts}" "$STORAGE_SAFETY_MIXED" "64 KiB per excerpt; 3 excerpts, 30 days, and 192 KiB per session soft limits" "newest unresolved recovery evidence per session" "Headless runtime computes a dry run after each preserved failure" "_storage_worker_excerpt_plan"
	_storage_emit_record "pulse-hot-log" "$pulse_producer" "${home_label}/.aidevops/logs/pulse.log" "${HOME:+$HOME/.aidevops/logs/pulse.log}" "$framework_owner" "$active_class" "50 MiB active-file cap with gzip archive rotation" "$protected_disposition" "$active_writer_reason" "Use pulse-owned rotate_pulse_log; never unlink the active file"
	_storage_emit_record "pulse-wrapper-log" "$pulse_producer" "${home_label}/.aidevops/logs/pulse-wrapper.log" "${HOME:+$HOME/.aidevops/logs/pulse-wrapper.log}" "$framework_owner" "$active_class" "50 MiB active-file cap with gzip archive rotation" "$protected_disposition" "$active_writer_reason" "Use pulse-owned rotate_pulse_log; never unlink the active file"
	_storage_emit_record "pulse-stage-timings" "$pulse_producer" "${home_label}/.aidevops/logs/pulse-stage-timings.log" "${HOME:+$HOME/.aidevops/logs/pulse-stage-timings.log}" "$framework_owner" "$active_class" "1 MiB active-file cap with gzip archive rotation" "$protected_disposition" "$active_writer_reason" "Use pulse-owned rotate_pulse_log; never unlink the active file"
	_storage_emit_record "pulse-log-archive" "$pulse_producer" "${home_label}/.aidevops/logs/pulse-archive" "${HOME:+$HOME/.aidevops/logs/pulse-archive}" "$framework_owner" "archive" "1 GiB combined cold archive cap; oldest archives first" "$protected_disposition" "archive already converged by producer" "Use pulse-owned rotate_pulse_log for archive pruning"
	_storage_opencode_records
	_storage_emit_record "npm-cache" "npm" "npm cache" "${AIDEVOPS_NPM_CACHE_DIR:-${HOME:+$HOME/.npm}}" "external" "cache" "package-manager owned; no aidevops cleanup authority" "protected" "external owner" "Use npm-owned diagnostics and cleanup explicitly"
	return 0
}

_storage_inventory_json() {
	local records=""
	local generated_at=""
	records=$(_storage_inventory_records)
	generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '%s\n' "$records" | jq -s \
		--argjson schema_version "$STORAGE_SCHEMA_VERSION" \
		--arg generated_at "$generated_at" \
		'{schema_version:$schema_version,generated_at:$generated_at,read_only:true,stores:.}'
	return 0
}

_storage_format_bytes() {
	local bytes="$1"
	if [[ "$bytes" == "$STORAGE_JSON_NULL" ]]; then
		printf 'unavailable'
	elif [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%s GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%s MiB' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	elif [[ "$bytes" -ge 1024 ]]; then
		printf '%s.%s KiB' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
	else
		printf '%s B' "$bytes"
	fi
	return 0
}

_storage_status() {
	local report=""
	local store_id=""
	local owner=""
	local safety_class=""
	local total=""
	local protected=""
	local reclaimable=""
	local unknown=""
	local confidence=""
	local reason=""
	local next_action=""
	local error=""
	report=$(_storage_inventory_json)
	printf 'Storage Inventory (read-only)\n'
	printf '%-24s %-10s %-10s %12s %12s %12s %12s %-11s\n' "Store" "Owner" "Class" "Total" "Protected" "Reclaimable" "Unknown" "Confidence"
	printf '%s\n' "$report" | jq -r '.stores[] | [.store_id,.owner,.safety_class,(.total_bytes|tostring),(.protected_bytes|tostring),(.reclaimable_bytes|tostring),(.unknown_bytes|tostring),.sizing_confidence,.protection_reasons[0],.next_action,(.error // "")] | @tsv' |
		while IFS=$'\t' read -r store_id owner safety_class total protected reclaimable unknown confidence reason next_action error; do
			printf '%-24s %-10s %-10s %12s %12s %12s %12s %-11s\n' \
				"$store_id" "$owner" "$safety_class" "$(_storage_format_bytes "$total")" "$(_storage_format_bytes "$protected")" "$(_storage_format_bytes "$reclaimable")" "$(_storage_format_bytes "$unknown")" "$confidence"
			printf '  reason: %s' "$reason"
			[[ -n "$error" ]] && printf ' (%s)' "$error"
			printf '\n'
			printf '  next: %s\n' "$next_action"
		done
	printf 'No cleanup was performed. Unknown or unavailable classifications are never reclaimable.\n'
	return 0
}

main() {
	local command_name="${1:-status}"
	case "$command_name" in
	status) _storage_status ;;
	json) _storage_inventory_json ;;
	help | --help | -h) _storage_usage ;;
	*)
		_storage_usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
