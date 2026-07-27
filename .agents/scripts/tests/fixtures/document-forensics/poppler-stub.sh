#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

fixture_field() {
	local field="$1"
	local file="$2"
	awk -F '=' -v wanted="$field" '$1 == wanted { value = $2 } END { print value }' "$file"
	return 0
}

write_text_output() {
	local output="$1"
	local text="$2"
	if [[ "$output" == "-" ]]; then
		printf '%s\n' "$text"
	else
		printf '%s\n' "$text" >"$output"
	fi
	return 0
}

tool="${0##*/}"
page=1
input=""
output=""
prefix=""
pattern=""
current=""

case "$tool" in
pdfinfo)
	while [[ $# -gt 0 ]]; do
		current="$1"
		case "$current" in
		-f)
			page="$2"
			shift 2
			;;
		-l)
			shift 2
			;;
		*)
			input="$current"
			shift
			;;
		esac
	done
	pages=$(fixture_field PAGES "$input")
	if [[ ! "$pages" =~ ^[0-9]+$ ]]; then
		pages=$(awk '/^(SOURCE_PAGE|PAGE_PDF)/ { count += 1 } END { print count + 0 }' "$input")
	fi
	dimensions=$(awk -v wanted="$page" '
		/^(SOURCE_PAGE|PAGE_PDF)/ {
			count += 1
			if (count == wanted) {
				for (field = 1; field <= NF; field += 1) {
					if ($field ~ /^dimensions=/) {
						sub(/^dimensions=/, "", $field)
						print $field
						exit
					}
				}
			}
		}
	' "$input")
	[[ "$dimensions" =~ ^[0-9]+x[0-9]+$ ]] || dimensions="612x792"
	width="${dimensions%x*}"
	height="${dimensions#*x}"
	printf 'Pages: %s\n' "$pages"
	printf 'Page %s size: %s x %s pts\n' "$page" "$width" "$height"
	;;
pdftotext)
	while [[ $# -gt 0 ]]; do
		current="$1"
		case "$current" in
		-f)
			page="$2"
			shift 2
			;;
		-l)
			shift 2
			;;
		-*) shift ;;
		*)
			if [[ -z "$input" ]]; then
				input="$current"
			else
				output="$current"
			fi
			shift
			;;
		esac
	done
	kind=$(fixture_field KIND "$input")
	text=""
	if [[ "$kind" == "searchable" ]] || \
		{ [[ "$kind" == "mixed" || "$kind" == "mixed-failure" ]] && [[ "$page" -eq 1 ]]; }; then
		text="Searchable source text for fixture ${kind} page ${page}. This page already has a healthy embedded text layer and must remain unchanged."
	fi
	write_text_output "$output" "$text"
	;;
pdftoppm)
	while [[ $# -gt 0 ]]; do
		current="$1"
		case "$current" in
		-f)
			page="$2"
			shift 2
			;;
		-l | -r) shift 2 ;;
		-singlefile | -png) shift ;;
		*)
			if [[ -z "$input" ]]; then
				input="$current"
			else
				prefix="$current"
			fi
			shift
			;;
		esac
	done
	kind=$(fixture_field KIND "$input")
	printf 'KIND=%s\nPAGE=%s\nTRANSFORM=rendered\nCANVAS=1200x1600\n' "$kind" "$page" >"${prefix}.png"
	;;
pdfseparate)
	while [[ $# -gt 0 ]]; do
		current="$1"
		case "$current" in
		-f)
			page="$2"
			shift 2
			;;
		-l) shift 2 ;;
		*)
			if [[ -z "$input" ]]; then
				input="$current"
			else
				pattern="$current"
			fi
			shift
			;;
		esac
	done
	kind=$(fixture_field KIND "$input")
	output="${pattern/\%d/$page}"
	printf 'SOURCE_PAGE kind=%s page=%s dimensions=612x792\n' "$kind" "$page" >"$output"
	;;
*)
	printf 'Unsupported fixture command: %s\n' "$tool" >&2
	exit 1
	;;
esac
