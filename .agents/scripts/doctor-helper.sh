#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# doctor-helper.sh — Detect and consolidate duplicate aidevops/opencode installs
#
# Finds all install locations for both `aidevops` and `opencode` binaries,
# identifies the install method for each, flags conflicts (PATH shadowing,
# version mismatches), and recommends consolidation.
#
# Usage:
#   doctor-helper.sh              # Full diagnostic report
#   doctor-helper.sh --fix        # Interactive consolidation (with confirmation)
#   doctor-helper.sh --json       # Machine-readable JSON output
#   doctor-helper.sh --quiet      # Exit code only (0=clean, 1=conflicts found)

set -euo pipefail

# Colors — sourced from shared-constants.sh (Pattern A, t2053.3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# BOLD and DIM are not in shared-constants.sh — Pattern B fallback
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'
[[ -z "${DIM+x}" ]] && DIM='\033[2m'

# Globals
CONFLICTS_FOUND=0
FIX_MODE=false
JSON_MODE=false
QUIET_MODE=false

# --- Utility functions ---

print_info() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${BLUE}[INFO]${NC} $1"
	return 0
}
print_success() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}
print_warning() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}
print_error() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}
print_header() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "\n${BOLD}${CYAN}$1${NC}"
	return 0
}
print_detail() {
	[[ "$QUIET_MODE" == "true" ]] && return 0
	echo -e "$1"
	return 0
}

# Resolve symlinks to find the real path (portable, bash 3.2 compatible)
resolve_path() {
	local path="$1"
	local resolved="$path"

	# Follow symlinks iteratively (bash 3.2 compatible — no readlink -f on macOS)
	while [[ -L "$resolved" ]]; do
		local dir
		dir="$(cd "$(dirname "$resolved")" && pwd)"
		resolved="$(readlink "$resolved")"
		# Handle relative symlinks
		if [[ "$resolved" != /* ]]; then
			resolved="$dir/$resolved"
		fi
	done

	# Normalise the path
	if [[ -e "$resolved" ]]; then
		(cd "$(dirname "$resolved")" && echo "$(pwd)/$(basename "$resolved")")
	else
		echo "$resolved"
	fi
	return 0
}

# Identify install method from a resolved binary path
identify_method() {
	local resolved_path="$1"

	case "$resolved_path" in
	*/node_modules/*)
		echo "npm"
		;;
	*/.bun/*)
		echo "bun"
		;;
	*/Cellar/* | */opt/homebrew/* | */usr/local/Homebrew/*)
		echo "brew"
		;;
	*/Git/aidevops/*)
		echo "git-repo"
		;;
	*/Git/opencode/*)
		echo "git-repo"
		;;
	*/.cargo/*)
		echo "cargo"
		;;
	*/go/bin/* | */gopath/*)
		echo "go"
		;;
	*)
		echo "unknown"
		;;
	esac
	return 0
}

# Get version from a binary
get_binary_version() {
	local binary_path="$1"
	local version=""

	# Try --version first, then -v, then version subcommand
	version=$("$binary_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	if [[ -z "$version" ]]; then
		version=$("$binary_path" -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	fi
	if [[ -z "$version" ]]; then
		version=$("$binary_path" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
	fi

	echo "${version:-unknown}"
	return 0
}

# Find all locations of a binary on PATH using `which -a` or `type -a`
find_all_locations() {
	local binary_name="$1"
	local locations=""

	# which -a is available on macOS and most Linux
	if locations=$(which -a "$binary_name" 2>/dev/null); then
		echo "$locations"
	elif locations=$(type -aP "$binary_name" 2>/dev/null); then
		echo "$locations"
	fi
	return 0
}

# Return the preferred install method for a binary
# Outputs: method name to stdout
get_preferred_method() {
	local binary_name="$1"

	if [[ "$binary_name" == "aidevops" ]]; then
		echo "git-repo"
	else
		echo "npm"
	fi
	return 0
}

# Build the remove command for a given install method and path
# Outputs: remove command string to stdout
build_remove_cmd() {
	local method="$1"
	local binary_name="$2"
	local path="$3"

	case "$method" in
	npm) echo "npm uninstall -g $binary_name" ;;
	bun) echo "bun remove -g $binary_name" ;;
	brew) echo "brew uninstall $binary_name" ;;
	cargo) echo "cargo uninstall $binary_name" ;;
	go) echo "rm $path" ;;
	*) echo "rm $path" ;;
	esac
	return 0
}

# Collect unique (deduplicated) install locations for a binary.
# Outputs four newline-delimited variables to stdout as a block:
#   UNIQUE_PATHS, UNIQUE_RESOLVED, UNIQUE_METHODS, UNIQUE_VERSIONS
# Each block is separated by a sentinel line "---".
# Callers parse with: read_collect_output <var> <block_index>
collect_unique_installs() {
	local binary_name="$1"
	local locations_raw="$2"

	local seen_resolved=""
	local unique_paths=""
	local unique_resolved=""
	local unique_methods=""
	local unique_versions=""

	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		local resolved
		resolved=$(resolve_path "$loc")
		local method
		method=$(identify_method "$resolved")

		# Skip already-seen resolved paths
		local already_seen=false
		while IFS= read -r seen; do
			[[ -z "$seen" ]] && continue
			if [[ "$seen" == "$resolved" ]]; then
				already_seen=true
				break
			fi
		done <<<"$seen_resolved"

		[[ "$already_seen" == "true" ]] && continue
		seen_resolved="${seen_resolved}${resolved}"$'\n'

		local version
		version=$(get_binary_version "$loc")

		unique_paths="${unique_paths}${loc}"$'\n'
		unique_resolved="${unique_resolved}${resolved}"$'\n'
		unique_methods="${unique_methods}${method}"$'\n'
		unique_versions="${unique_versions}${version}"$'\n'
	done <<<"$locations_raw"

	# Output as four blocks separated by sentinel
	printf '%s' "$unique_paths"
	printf '%s\n' "---"
	printf '%s' "$unique_resolved"
	printf '%s\n' "---"
	printf '%s' "$unique_methods"
	printf '%s\n' "---"
	printf '%s' "$unique_versions"
	return 0
}

# --- Core diagnostic functions ---

# Report a single clean install
report_single_install() {
	local binary_name="$1"
	local active_path="$2"
	local active_method="$3"
	local active_version="$4"

	local resolved
	resolved=$(resolve_path "$active_path")
	print_success "$binary_name: 1 install found"
	print_detail "  ${DIM}Path:${NC}    $active_path"
	if [[ "$active_path" != "$resolved" ]]; then
		print_detail "  ${DIM}Target:${NC}  $resolved"
	fi
	print_detail "  ${DIM}Method:${NC}  $active_method"
	print_detail "  ${DIM}Version:${NC} $active_version"
	return 0
}

# Report conflict installs and check for version mismatches
report_conflict_installs() {
	local binary_name="$1"
	local location_count="$2"
	local unique_paths="$3"
	local unique_resolved="$4"
	local unique_methods="$5"
	local unique_versions="$6"

	CONFLICTS_FOUND=1
	print_warning "$binary_name: $location_count installs found (conflict!)"
	print_detail ""

	local idx=0
	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		idx=$((idx + 1))

		local resolved=""
		local method=""
		local version=""

		resolved=$(echo "$unique_resolved" | sed -n "${idx}p")
		method=$(echo "$unique_methods" | sed -n "${idx}p")
		version=$(echo "$unique_versions" | sed -n "${idx}p")

		if [[ $idx -eq 1 ]]; then
			print_detail "  ${GREEN}#$idx (active on PATH)${NC}"
		else
			print_detail "  ${YELLOW}#$idx (shadowed)${NC}"
		fi
		print_detail "    ${DIM}Path:${NC}    $loc"
		if [[ "$loc" != "$resolved" ]]; then
			print_detail "    ${DIM}Target:${NC}  $resolved"
		fi
		print_detail "    ${DIM}Method:${NC}  $method"
		print_detail "    ${DIM}Version:${NC} $version"
		print_detail ""
	done <<<"$unique_paths"

	# Check for version mismatches
	local first_version=""
	local version_mismatch=false
	while IFS= read -r ver; do
		[[ -z "$ver" ]] && continue
		[[ "$ver" == "unknown" ]] && continue
		if [[ -z "$first_version" ]]; then
			first_version="$ver"
		elif [[ "$ver" != "$first_version" ]]; then
			version_mismatch=true
			break
		fi
	done <<<"$unique_versions"

	if [[ "$version_mismatch" == "true" ]]; then
		print_error "Version mismatch detected across installs!"
		print_detail "  This means \`$binary_name update\` may update one copy while the"
		print_detail "  stale copy continues to run from PATH."
	fi

	return 0
}

#######################################
# Report whether a custom model-routing table is usable or partially ignored.
#######################################
diagnose_model_routing_table() {
	local routing_table=""
	local framework_table=""
	local findings=""

	if ! declare -F model_routing_table_path >/dev/null 2>&1 || ! declare -F model_routing_framework_table_path >/dev/null 2>&1; then
		print_warning "Model routing override: validator unavailable"
		CONFLICTS_FOUND=1
		return 0
	fi

	routing_table=$(model_routing_table_path 2>/dev/null) || routing_table=""
	framework_table=$(model_routing_framework_table_path 2>/dev/null) || framework_table=""
	if [[ -z "$routing_table" || "$routing_table" == "$framework_table" ]]; then
		print_info "Model routing override: not found; framework defaults active"
		return 0
	fi

	findings=$(model_routing_custom_table_validation_findings "$routing_table" "$framework_table") || findings="document: validation failed"
	if [[ -n "$findings" ]]; then
		print_warning "Model routing override: found and parsed, but invalid tiers are ignored: ${findings//$'\n'/; }"
		CONFLICTS_FOUND=1
		return 0
	fi

	print_success "Model routing override: found and parsed; configured tiers are active"
	return 0
}

# Diagnose a single binary (aidevops or opencode)
diagnose_binary() {
	local binary_name="$1"
	local locations_raw=""

	print_header "Checking: $binary_name"

	locations_raw=$(find_all_locations "$binary_name")

	if [[ -z "$locations_raw" ]]; then
		print_info "$binary_name is not installed"
		return 0
	fi

	# Collect unique installs — parse the four blocks from stdout
	local collected
	collected=$(collect_unique_installs "$binary_name" "$locations_raw")

	local unique_paths unique_resolved unique_methods unique_versions
	unique_paths=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==0{print}')
	unique_resolved=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==1{print}')
	unique_methods=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==2{print}')
	unique_versions=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==3{print}')

	local location_count=0
	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		location_count=$((location_count + 1))
	done <<<"$unique_paths"

	if [[ $location_count -eq 0 ]]; then
		print_info "$binary_name is not installed"
		return 0
	fi

	local active_path active_method active_version
	active_path=$(echo "$unique_paths" | sed -n '1p')
	active_method=$(echo "$unique_methods" | sed -n '1p')
	active_version=$(echo "$unique_versions" | sed -n '1p')

	if [[ $location_count -eq 1 ]]; then
		report_single_install "$binary_name" "$active_path" "$active_method" "$active_version"
		return 0
	fi

	report_conflict_installs "$binary_name" "$location_count" \
		"$unique_paths" "$unique_resolved" "$unique_methods" "$unique_versions"

	recommend_consolidation "$binary_name" "$unique_paths" "$unique_methods" "$active_path" "$active_method"

	return 0
}

# Recommend which install to keep and which to remove
recommend_consolidation() {
	local binary_name="$1"
	local paths="$2"
	local methods="$3"
	local active_path="$4"
	local active_method="$5"

	local preferred_method
	preferred_method=$(get_preferred_method "$binary_name")

	print_header "Recommendation for $binary_name"

	if [[ "$active_method" == "$preferred_method" ]]; then
		print_success "Active install uses the recommended method ($preferred_method)"
		print_detail "  Remove the other installs to prevent future confusion:"
	else
		print_warning "Active install uses $active_method, but $preferred_method is recommended"
		print_detail "  The $preferred_method install should take PATH priority."
		print_detail "  Remove the others and ensure $preferred_method is first on PATH:"
	fi

	print_detail ""

	local idx=0
	while IFS= read -r method; do
		[[ -z "$method" ]] && continue
		idx=$((idx + 1))
		local path
		path=$(echo "$paths" | sed -n "${idx}p")

		if [[ "$method" == "$preferred_method" ]]; then
			print_detail "  ${GREEN}KEEP${NC}   [$method] $path"
		else
			local remove_cmd
			remove_cmd=$(build_remove_cmd "$method" "$binary_name" "$path")
			print_detail "  ${RED}REMOVE${NC} [$method] $path"
			print_detail "         ${DIM}Run: $remove_cmd${NC}"
		fi
	done <<<"$methods"

	print_detail ""
	return 0
}

# Execute removal of a single install interactively
execute_removal() {
	local binary_name="$1"
	local method="$2"
	local path="$3"

	local remove_cmd
	remove_cmd=$(build_remove_cmd "$method" "$binary_name" "$path")

	echo ""
	echo -e "${YELLOW}Remove $binary_name [$method] at $path?${NC}"
	echo -e "  Command: $remove_cmd"
	echo -n "  Proceed? [y/N] "
	read -r confirm
	if [[ "$confirm" =~ ^[Yy]$ ]]; then
		echo -e "  ${BLUE}Running:${NC} $remove_cmd"
		local success=false
		case "$method" in
		npm)
			if npm uninstall -g "$binary_name" 2>&1; then success=true; fi
			;;
		bun)
			if bun remove -g "$binary_name" 2>&1; then success=true; fi
			;;
		brew)
			if brew uninstall "$binary_name" 2>&1; then success=true; fi
			;;
		cargo)
			if cargo uninstall "$binary_name" 2>&1; then success=true; fi
			;;
		*)
			if rm "$path" 2>&1; then success=true; fi
			;;
		esac
		if $success; then
			print_success "Removed $binary_name [$method]"
		else
			print_error "Failed to remove $binary_name [$method]"
		fi
	else
		print_info "Skipped $binary_name [$method]"
	fi
	return 0
}

# Interactive fix mode — remove duplicates with user confirmation
run_fix() {
	local binary_name="$1"

	local locations_raw=""
	locations_raw=$(find_all_locations "$binary_name")
	[[ -z "$locations_raw" ]] && return 0

	# Collect unique installs
	local collected
	collected=$(collect_unique_installs "$binary_name" "$locations_raw")

	local unique_paths unique_methods
	unique_paths=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==0{print}')
	unique_methods=$(echo "$collected" | awk 'BEGIN{b=0} /^---$/{b++;next} b==2{print}')

	local count=0
	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		count=$((count + 1))
	done <<<"$unique_paths"

	[[ $count -le 1 ]] && return 0

	local preferred_method
	preferred_method=$(get_preferred_method "$binary_name")

	local idx=0
	while IFS= read -r method; do
		[[ -z "$method" ]] && continue
		idx=$((idx + 1))

		[[ "$method" == "$preferred_method" ]] && continue

		local path
		path=$(echo "$unique_paths" | sed -n "${idx}p")
		execute_removal "$binary_name" "$method" "$path"
	done <<<"$unique_methods"

	return 0
}

# --- JSON output ---

json_diagnose_binary() {
	local binary_name="$1"
	local locations_raw=""
	locations_raw=$(find_all_locations "$binary_name")

	if [[ -z "$locations_raw" ]]; then
		echo "  \"$binary_name\": { \"installed\": false, \"locations\": [] }"
		return 0
	fi

	local entries=""
	local seen_resolved=""
	local count=0
	local first_entry=true

	while IFS= read -r loc; do
		[[ -z "$loc" ]] && continue
		local resolved
		resolved=$(resolve_path "$loc")

		local already_seen=false
		while IFS= read -r seen; do
			[[ -z "$seen" ]] && continue
			if [[ "$seen" == "$resolved" ]]; then
				already_seen=true
				break
			fi
		done <<<"$seen_resolved"

		[[ "$already_seen" == "true" ]] && continue
		seen_resolved="${seen_resolved}${resolved}"$'\n'

		local method
		method=$(identify_method "$resolved")
		local version
		version=$(get_binary_version "$loc")
		count=$((count + 1))

		local is_active="false"
		[[ $count -eq 1 ]] && is_active="true"

		if [[ "$first_entry" == "true" ]]; then
			first_entry=false
		else
			entries="${entries},"
		fi

		local current_entry
		current_entry=$(jq -n \
			--arg path "$loc" \
			--arg resolved "$resolved" \
			--arg method "$method" \
			--arg version "$version" \
			--argjson active "$is_active" \
			'{path: $path, resolved: $resolved, method: $method, version: $version, active: $active}')
		entries="${entries}
      ${current_entry}"
	done <<<"$locations_raw"

	local has_conflicts="false"
	[[ $count -gt 1 ]] && has_conflicts="true"

	echo "  \"$binary_name\": {
    \"installed\": true,
    \"conflict\": $has_conflicts,
    \"location_count\": $count,
    \"locations\": [$entries
    ]
  }"
	return 0
}

# --- Main ---

main() {
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--fix)
			FIX_MODE=true
			shift
			;;
		--json)
			JSON_MODE=true
			shift
			;;
		--quiet | -q)
			QUIET_MODE=true
			shift
			;;
		--help | -h)
			echo "Usage: doctor-helper.sh [--fix] [--json] [--quiet]"
			echo ""
			echo "Detect and consolidate duplicate aidevops/opencode installs."
			echo ""
			echo "Options:"
			echo "  --fix     Interactive removal of duplicate installs"
			echo "  --json    Machine-readable JSON output"
			echo "  --quiet   Exit code only (0=clean, 1=conflicts)"
			echo "  --help    Show this help"
			return 0
			;;
		*)
			echo "Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	if [[ "$JSON_MODE" == "true" ]]; then
		echo "{"
		json_diagnose_binary "aidevops"
		echo ","
		json_diagnose_binary "opencode"
		echo ""
		echo "}"
		return 0
	fi

	if [[ "$FIX_MODE" == "true" ]]; then
		print_header "AI DevOps Doctor — Fix Mode"
		echo "This will interactively remove duplicate installs."
		echo ""
		run_fix "aidevops"
		run_fix "opencode"
		echo ""
		print_info "Re-running diagnostics..."
		echo ""
		diagnose_binary "aidevops"
		diagnose_binary "opencode"
		return 0
	fi

	if [[ "$QUIET_MODE" != "true" ]]; then
		print_header "AI DevOps Doctor"
		echo -e "${DIM}Checking for duplicate or conflicting installs...${NC}"
	fi

	diagnose_binary "aidevops"
	diagnose_binary "opencode"
	diagnose_model_routing_table

	if [[ "$QUIET_MODE" != "true" ]]; then
		echo ""
		if [[ $CONFLICTS_FOUND -eq 0 ]]; then
			print_success "No conflicts detected. All clean!"
		else
			print_warning "Conflicts detected. Run 'aidevops doctor --fix' to resolve interactively."
		fi
	fi

	return $CONFLICTS_FOUND
}

main "$@"
