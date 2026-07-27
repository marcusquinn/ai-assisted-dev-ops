#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

output="$1"
shift
: >"$output"
for page_file in "$@"; do
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line" >>"$output"
	done <"$page_file"
done
