#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Canonical infrastructure-advisory predicate shared by Pulse dispatch gates.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_INFRASTRUCTURE_ADVISORY_LIB_LOADED:-}" ]] && return 0
_INFRASTRUCTURE_ADVISORY_LIB_LOADED=1

# Print the jq definition used against a labels array. Infrastructure is a
# general work category; only CI failure-miner infrastructure issues are
# operational advisories that must remain outside worker dispatch.
infrastructure_advisory_jq_definition() {
	# shellcheck disable=SC2016  # jq variables are literal program syntax
	printf '%s\n' '
		def aidevops_infrastructure_advisory:
			map(.name? // .) as $labels |
			(($labels | index("infrastructure")) != null and
			 ($labels | index("source:ci-failure-miner")) != null);'
	return 0
}
