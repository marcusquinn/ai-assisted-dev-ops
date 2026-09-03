#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared managed-label provisioning primitives
# =============================================================================
# Callers provide inventory and create runner functions so wrapper and PATH-shim
# transports share one canonical label catalogue without recursive gh calls.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_MANAGED_LABEL_PROVISIONING_LIB_LOADED:-}" ]] && return 0
_MANAGED_LABEL_PROVISIONING_LIB_LOADED=1

_MANAGED_ORIGIN_LABEL_SPECS=(
	"origin:worker" "Created by headless/pulse worker session" "C5DEF5"
	"origin:interactive" "Created by interactive user session" "BFD4F2"
	"origin:worker-takeover" "Worker took over from interactive session" "D4C5F9"
)

_MANAGED_APPROVAL_HOLD_LABEL_SPECS=(
	"needs-maintainer-review" "Requires maintainer approval before automated dispatch" "FBCA04"
)

_MANAGED_APPROVAL_ISSUE_LABEL_SPECS=(
	"${_MANAGED_APPROVAL_HOLD_LABEL_SPECS[@]}"
	"auto-dispatch" "Eligible for autonomous worker dispatch" "0E8A16"
	"no-auto-dispatch" "Opt-out: block all auto-dispatch on this issue" "EDEDED"
)

managed_label_snapshot_has() {
	local snapshot="$1"
	local expected_name="$2"
	local actual_name=""
	while IFS= read -r actual_name; do
		[[ "$actual_name" == "$expected_name" ]] && return 0
	done <<<"$snapshot"
	return 1
}

managed_labels_ensure_specs() {
	local repo="$1"
	local inventory_runner="$2"
	local create_runner="$3"
	shift 3
	[[ -n "$repo" && -n "$inventory_runner" && -n "$create_runner" ]] || return 1
	[[ $(($# % 3)) -eq 0 ]] || return 1

	local labels_snapshot=""
	labels_snapshot=$("$inventory_runner" "$repo") || return 1
	local label_name=""
	local label_description=""
	local label_color=""
	while [[ $# -gt 0 ]]; do
		label_name="$1"
		label_description="$2"
		label_color="$3"
		shift 3
		if ! managed_label_snapshot_has "$labels_snapshot" "$label_name"; then
			"$create_runner" "$repo" "$label_name" "$label_description" "$label_color" || return 1
			labels_snapshot="${labels_snapshot}${labels_snapshot:+$'\n'}${label_name}"
		fi
	done
	return 0
}

managed_labels_ensure_origin_set() {
	local repo="$1"
	local inventory_runner="$2"
	local create_runner="$3"
	managed_labels_ensure_specs "$repo" "$inventory_runner" "$create_runner" \
		"${_MANAGED_ORIGIN_LABEL_SPECS[@]}"
	return $?
}

managed_labels_ensure_tracking_set() {
	local repo="$1"
	local inventory_runner="$2"
	local create_runner="$3"
	local -a tracking_specs=(
		"${_MANAGED_ORIGIN_LABEL_SPECS[@]}"
		"status:in-review" "PR open, awaiting review/merge" "5319E7"
		"bug" "Something isn't working" "D73A4A"
	)
	managed_labels_ensure_specs "$repo" "$inventory_runner" "$create_runner" \
		"${tracking_specs[@]}"
	return $?
}

managed_labels_ensure_approval_set() {
	local repo="$1"
	local target_type="$2"
	local inventory_runner="$3"
	local create_runner="$4"
	local -a approval_specs=()

	case "$target_type" in
	issue) approval_specs=("${_MANAGED_APPROVAL_ISSUE_LABEL_SPECS[@]}") ;;
	pr) approval_specs=("${_MANAGED_APPROVAL_HOLD_LABEL_SPECS[@]}") ;;
	*) return 1 ;;
	esac

	managed_labels_ensure_specs "$repo" "$inventory_runner" "$create_runner" \
		"${approval_specs[@]}"
	return $?
}
