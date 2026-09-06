#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2181
set -euo pipefail

# Secretlint Integration Script
# Pluggable linting tool to prevent committing credentials and secrets
#
# Usage: ./secretlint-helper.sh [command] [options]
# Commands:
#   install     - Install Secretlint and recommended rules
#   init        - Initialize project configuration
#   scan        - Scan for secrets (alias for lint)
#   lint        - Lint files for secrets
#   mask        - Mask secrets in a file
#   status      - Check installation and configuration
#   fix         - Mask secrets and fix files in place
#   quick       - Quick scan without installation (npx)
#   docker      - Run scan via Docker
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.2.0
# License: MIT
# Reference: https://github.com/secretlint/secretlint

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Common constants
readonly SECRETLINT_CONFIG_FILE=".secretlintrc.json"
readonly SECRETLINT_IGNORE_FILE=".secretlintignore"
readonly DEFAULT_GLOB_PATTERN="**/*"

# =============================================================================
# Git Worktree Support
# =============================================================================
# In a git worktree, .git is a file (not a directory) and node_modules lives
# in the main repo root, not the worktree. These helpers resolve the correct
# paths for install, scan, and hook operations.
#
# git rev-parse --git-common-dir:
#   - In the main worktree: returns ".git" (relative to CWD)
#   - In a linked worktree: returns an absolute path to the main .git dir
# Both cases are handled by: cd "$git_common_dir/.." && pwd
#   - Relative ".git": cd resolves relative to CWD → repo root
#   - Absolute path: cd resolves to main repo root

# Detect if running inside a git worktree (linked worktree, not the main one)
is_git_worktree() {
	local git_dir git_common_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
	git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
	# In a linked worktree, git-dir differs from git-common-dir
	[[ "${git_dir}" != "${git_common_dir}" ]]
	return $?
}

# Get the main repo root (where package.json and node_modules live)
# In a worktree this resolves to the main repo; otherwise returns CWD toplevel.
# Uses git rev-parse --git-common-dir which returns:
#   - ".git" (relative) in the main worktree → cd .git/.. = repo root
#   - "/abs/path/to/.git" in a linked worktree → cd /abs/path/to/.git/.. = main repo root
get_repo_root() {
	local git_common_dir repo_root
	git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
		pwd
		return 0
	}
	# cd handles both relative (".git") and absolute paths correctly
	repo_root=$(cd "${git_common_dir}/.." && pwd) || {
		pwd
		return 0
	}
	echo "${repo_root}"
	return 0
}

# Get the real .git directory path (works in both regular repos and worktrees)
get_git_dir() {
	git rev-parse --git-dir 2>/dev/null || echo ".git"
	return 0
}

# Print functions
print_header() {
	local message="$1"
	echo -e "${PURPLE}🔐 ${message}${NC}"
	return 0
}

print_secret() {
	local message="$1"
	echo -e "${CYAN}🛡️  ${message}${NC}"
	return 0
}

# Check if Secretlint is installed
# Searches: global PATH, CWD node_modules, main repo node_modules (worktree)
check_secretlint_installed() {
	local version repo_root
	if command -v secretlint &>/dev/null; then
		version=$(secretlint --version 2>/dev/null || echo "unknown")
		print_success "Secretlint installed: v${version}"
		return 0
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		version=$(./node_modules/.bin/secretlint --version 2>/dev/null || echo "unknown")
		print_success "Secretlint installed (local): v${version}"
		return 0
	else
		# Check main repo node_modules (handles git worktrees)
		repo_root=$(get_repo_root)
		if [[ "${repo_root}" != "$(pwd)" ]] && [[ -f "${repo_root}/node_modules/.bin/secretlint" ]]; then
			version=$("${repo_root}/node_modules/.bin/secretlint" --version 2>/dev/null || echo "unknown")
			print_success "Secretlint installed (main repo): v${version}"
			return 0
		fi
		print_warning "Secretlint not found"
		return 1
	fi
}

# Check if a package is installed locally, in main repo, or globally
# Usage: _is_npm_pkg_installed <package> <repo_root>
_is_npm_pkg_installed() {
	local pkg="$1"
	local repo_root="$2"
	npm list "${pkg}" &>/dev/null && return 0
	# Check main repo node_modules when in a worktree
	if [[ "${repo_root}" != "$(pwd)" ]]; then
		npm list --prefix "${repo_root}" "${pkg}" &>/dev/null && return 0
	fi
	npm list -g "${pkg}" &>/dev/null && return 0
	return 1
}

# Check if required rule presets are installed
# Returns: 0=all rules installed, 1=missing rules, 2=no config
# Checks CWD, main repo (worktree), and global installations
check_rules_installed() {
	local config_file="${1:-${SECRETLINT_CONFIG_FILE}}"

	if [[ ! -f "${config_file}" ]]; then
		return 2
	fi

	local repo_root
	repo_root=$(get_repo_root)

	# Extract rule IDs from config and check each
	local missing_rules=()

	# Check for preset-recommend (most common)
	if grep -q "secretlint-rule-preset-recommend" "${config_file}"; then
		if ! _is_npm_pkg_installed "@secretlint/secretlint-rule-preset-recommend" "${repo_root}"; then
			missing_rules+=("@secretlint/secretlint-rule-preset-recommend")
		fi
	fi

	# Check for pattern rule
	if grep -q "secretlint-rule-pattern" "${config_file}"; then
		if ! _is_npm_pkg_installed "@secretlint/secretlint-rule-pattern" "${repo_root}"; then
			missing_rules+=("@secretlint/secretlint-rule-pattern")
		fi
	fi

	if [[ ${#missing_rules[@]} -gt 0 ]]; then
		print_error "Missing required secretlint rules:"
		local rule
		for rule in "${missing_rules[@]}"; do
			echo "  - ${rule}"
		done
		print_info "Install with: npm install --save-dev ${missing_rules[*]}"
		return 1
	fi

	return 0
}

# Validate secretlint installation (binary + rules)
validate_secretlint_setup() {
	local has_issues=0 rules_exit

	# Check binary
	check_secretlint_installed || has_issues=1

	# Check rules - exit code 1 means missing rules, exit code 2 means no config (ok)
	check_rules_installed || rules_exit=$?
	rules_exit="${rules_exit:-0}"
	if [[ "${rules_exit}" -eq 1 ]]; then
		has_issues=1
	fi

	return "${has_issues}"
}

# Check if Docker is available
check_docker_available() {
	if command -v docker &>/dev/null; then
		print_success "Docker available"
		return 0
	else
		print_warning "Docker not found"
		return 1
	fi
}

# Get secretlint command (global, local, main repo, or npx fallback)
get_secretlint_cmd() {
	local repo_root
	if command -v secretlint &>/dev/null; then
		echo "secretlint"
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		echo "./node_modules/.bin/secretlint"
	else
		# Check main repo node_modules (handles git worktrees)
		repo_root=$(get_repo_root)
		if [[ "${repo_root}" != "$(pwd)" ]] && [[ -f "${repo_root}/node_modules/.bin/secretlint" ]]; then
			echo "${repo_root}/node_modules/.bin/secretlint"
		else
			echo "npx secretlint"
		fi
	fi
	return 0
}

# Install Secretlint and recommended rules
# In a worktree, installs to the main repo root (where package.json lives)
install_secretlint() {
	local install_type="${1:-local}"

	print_header "Installing Secretlint"

	# Check for Node.js
	if ! command -v node &>/dev/null; then
		print_error "Node.js is required. Please install Node.js 20+ first."
		print_info "Alternatively, use Docker: $0 docker scan"
		return 1
	fi

	local node_version
	node_version=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
	if [[ -z "${node_version}" ]] || ! [[ "${node_version}" =~ ^[0-9]+$ ]]; then
		print_warning "Could not determine Node.js version"
	elif [[ "${node_version}" -lt 18 ]]; then
		local node_v
		node_v=$(node -v)
		print_warning "Node.js 20+ recommended. Current version: ${node_v}"
	fi

	local repo_root install_exit=0
	case "${install_type}" in
	"global")
		print_info "Installing Secretlint globally..."
		npm install -g secretlint @secretlint/secretlint-rule-preset-recommend || install_exit=$?
		;;
	"local" | *)
		repo_root=$(get_repo_root)
		if [[ "${repo_root}" != "$(pwd)" ]] && [[ -f "${repo_root}/package.json" ]]; then
			print_info "Worktree detected. Installing in main repo: ${repo_root}"
			npm install --prefix "${repo_root}" --save-dev secretlint @secretlint/secretlint-rule-preset-recommend || install_exit=$?
		else
			print_info "Installing Secretlint locally..."
			npm install --save-dev secretlint @secretlint/secretlint-rule-preset-recommend || install_exit=$?
		fi
		;;
	esac

	if [[ ${install_exit} -eq 0 ]]; then
		print_success "Secretlint installed successfully"

		# Initialize if config doesn't exist
		if [[ ! -f "${SECRETLINT_CONFIG_FILE}" ]]; then
			print_info "Initializing configuration..."
			init_secretlint_config
		fi

		return 0
	else
		print_error "Installation failed"
		return 1
	fi
}

# Install additional rules
# In a worktree, installs to the main repo root
install_additional_rules() {
	local rules="${1:-pattern}"

	print_header "Installing Additional Secretlint Rules"

	local npm_prefix=""
	local repo_root
	if command -v secretlint &>/dev/null; then
		# Global secretlint → install globally
		npm_prefix="-g"
	else
		# In a worktree, install to the main repo
		repo_root=$(get_repo_root)
		if [[ "${repo_root}" != "$(pwd)" ]] && [[ -f "${repo_root}/package.json" ]]; then
			npm_prefix="--prefix ${repo_root} --save-dev"
		else
			npm_prefix="--save-dev"
		fi
	fi

	local install_exit=0
	case "${rules}" in
	"pattern")
		print_info "Installing custom pattern rule..."
		# shellcheck disable=SC2086
		npm install ${npm_prefix} @secretlint/secretlint-rule-pattern || install_exit=$?
		;;
	"sarif")
		print_info "Installing SARIF formatter..."
		# shellcheck disable=SC2086
		npm install ${npm_prefix} @secretlint/secretlint-formatter-sarif || install_exit=$?
		;;
	"all")
		print_info "Installing all recommended additional rules..."
		# shellcheck disable=SC2086
		npm install ${npm_prefix} \
			@secretlint/secretlint-rule-pattern \
			@secretlint/secretlint-rule-no-k8s-kind-secret \
			@secretlint/secretlint-rule-no-homedir \
			@secretlint/secretlint-rule-no-dotenv \
			@secretlint/secretlint-formatter-sarif || install_exit=$?
		;;
	*)
		print_info "Installing rule: ${rules}"
		# shellcheck disable=SC2086
		npm install ${npm_prefix} "${rules}" || install_exit=$?
		;;
	esac

	if [[ ${install_exit} -eq 0 ]]; then
		print_success "Additional rules installed"
		return 0
	else
		print_error "Failed to install rules"
		return 1
	fi
}

# Initialize Secretlint configuration
init_secretlint_config() {
	print_header "Initializing Secretlint Configuration"

	local cmd
	cmd=$(get_secretlint_cmd)

	if [[ -f "${SECRETLINT_CONFIG_FILE}" ]]; then
		print_warning "Configuration already exists: ${SECRETLINT_CONFIG_FILE}"
		print_info "Use 'secretlint --init' to overwrite"
		return 0
	fi

	# Try to use secretlint --init
	if ${cmd} --init &>/dev/null; then
		print_success "Configuration initialized: ${SECRETLINT_CONFIG_FILE}"
	else
		# Manually create comprehensive config
		print_info "Creating comprehensive configuration..."
		create_comprehensive_config
	fi

	# Create ignore file if it doesn't exist
	if [[ ! -f "${SECRETLINT_IGNORE_FILE}" ]]; then
		create_ignore_file
	fi

	return 0
}

# Create comprehensive configuration
create_comprehensive_config() {
	cat >"${SECRETLINT_CONFIG_FILE}" <<'EOF'
{
  "rules": [
    {
      "id": "@secretlint/secretlint-rule-preset-recommend",
      "rules": [
        {
          "id": "@secretlint/secretlint-rule-aws",
          "options": {
            "allows": []
          }
        },
        {
          "id": "@secretlint/secretlint-rule-github",
          "options": {
            "allows": []
          }
        },
        {
          "id": "@secretlint/secretlint-rule-privatekey"
        },
        {
          "id": "@secretlint/secretlint-rule-basicauth"
        },
        {
          "id": "@secretlint/secretlint-rule-slack"
        },
        {
          "id": "@secretlint/secretlint-rule-sendgrid"
        },
        {
          "id": "@secretlint/secretlint-rule-openai"
        },
        {
          "id": "@secretlint/secretlint-rule-anthropic"
        },
        {
          "id": "@secretlint/secretlint-rule-gcp"
        },
        {
          "id": "@secretlint/secretlint-rule-npm"
        },
        {
          "id": "@secretlint/secretlint-rule-shopify"
        },
        {
          "id": "@secretlint/secretlint-rule-linear"
        },
        {
          "id": "@secretlint/secretlint-rule-1password"
        },
        {
          "id": "@secretlint/secretlint-rule-database-connection-string"
        }
      ]
    }
  ]
}
EOF
	print_success "Created comprehensive configuration: ${SECRETLINT_CONFIG_FILE}"
	return 0
}

# Create ignore file
create_ignore_file() {
	cat >"${SECRETLINT_IGNORE_FILE}" <<'EOF'
# Secretlint Ignore File
# Uses .gitignore syntax

# Dependencies
**/node_modules/**
**/vendor/**
**/.venv/**
**/venv/**

# Build outputs
**/dist/**
**/build/**
**/.next/**
**/out/**

# IDE and editor
**/.idea/**
**/.vscode/**
**/.vs/**
*.swp
*.swo

# Git
**/.git/**

# Test fixtures (may contain fake secrets for testing)
**/test/fixtures/**
**/tests/fixtures/**
**/__tests__/fixtures/**
**/testdata/**

# Generated files
**/*.min.js
**/*.min.css
**/package-lock.json
**/pnpm-lock.yaml
**/yarn.lock
**/composer.lock
**/Gemfile.lock
**/Cargo.lock
**/poetry.lock

# Documentation and examples (review manually if needed)
**/docs/**
**/examples/**

# Binary files
**/*.png
**/*.jpg
**/*.jpeg
**/*.gif
**/*.ico
**/*.svg
**/*.woff
**/*.woff2
**/*.ttf
**/*.eot
**/*.pdf
**/*.zip
**/*.tar
**/*.gz
**/*.rar

# Logs
**/*.log
**/logs/**

# Coverage reports
**/coverage/**
**/.nyc_output/**

# Cache
**/.cache/**
**/.tmp/**
**/tmp/**
EOF
	print_success "Created ignore file: ${SECRETLINT_IGNORE_FILE}"
	return 0
}

# Run Secretlint scan
run_secretlint_scan() {
	local target="${1:-${DEFAULT_GLOB_PATTERN}}"
	local format="${2:-stylish}"
	local output_file="${3:-}"
	local extra_args="${4:-}"

	print_header "Running Secretlint Scan"

	# Validate target pattern for dangerous characters
	if [[ "${target}" == *";"* ]] || [[ "${target}" == *"|"* ]] || [[ "${target}" == *"&"* ]] || [[ "${target}" == *"\`"* ]]; then
		print_error "Invalid target pattern: contains forbidden characters"
		return 1
	fi

	# Scanning must not initialize configuration or select an installing runner.
	if [[ ! -f "${SECRETLINT_CONFIG_FILE}" ]]; then
		print_error "No configuration found. Run: $0 init"
		return 2
	fi

	local cmd
	cmd=$(get_secretlint_cmd)

	# Validate that required rules are installed
	local rules_check=0
	check_rules_installed "${SECRETLINT_CONFIG_FILE}" || rules_check=$?
	if [[ "${rules_check}" -eq 1 ]]; then
		print_error "Secretlint rules not properly installed. Run: $0 install"
		return 2
	fi

	# Build command array for safe execution
	local cmd_array
	cmd_array=()
	read -ra cmd_array <<<"${cmd}"
	cmd_array+=("${target}" "--format" "${format}")

	if [[ -n "${output_file}" ]]; then
		cmd_array+=("--output" "${output_file}")
	fi

	# Handle extra_args safely by splitting on spaces (limited use case)
	local extra_array
	extra_array=()
	if [[ -n "${extra_args}" ]]; then
		read -ra extra_array <<<"${extra_args}"
		cmd_array+=("${extra_array[@]}")
	fi

	print_info "Scanning: ${target}"
	print_info "Format: ${format}"
	print_info "Command: ${cmd_array[*]}"
	echo ""

	# Execute scan using array (safe from injection)
	"${cmd_array[@]}"
	local exit_code=$?

	echo ""
	if [[ ${exit_code} -eq 0 ]]; then
		print_success "No secrets detected! Your code is clean."
	elif [[ ${exit_code} -eq 1 ]]; then
		print_error "Secrets detected! Please review and remove/rotate exposed credentials."
		print_info "Tip: Use 'secretlint-disable-line' comments to ignore false positives"
	elif [[ ${exit_code} -eq 2 ]]; then
		print_error "Scan failed - configuration or installation error"
		print_info "Run: $0 status (to diagnose)"
		print_info "Run: $0 install (to fix installation)"
	else
		print_error "Scan failed with error code: ${exit_code}"
	fi

	return "${exit_code}"
}

# Run quick scan via npx (no installation)
run_quick_scan() {
	local target="${1:-${DEFAULT_GLOB_PATTERN}}"

	# Validate target pattern for dangerous characters
	if [[ "${target}" == *";"* ]] || [[ "${target}" == *"|"* ]] || [[ "${target}" == *"&"* ]] || [[ "${target}" == *"\`"* ]]; then
		print_error "Invalid target pattern: contains forbidden characters"
		return 1
	fi

	print_header "Quick Secretlint Scan (via npx)"
	print_info "This requires no installation"

	npx @secretlint/quick-start "${target}"
}

# Run scan via Docker
run_docker_scan() {
	local target="${1:-${DEFAULT_GLOB_PATTERN}}"
	local extra_args="${2:-}"

	print_header "Running Secretlint via Docker"

	# Validate target pattern for dangerous characters
	if [[ "${target}" == *";"* ]] || [[ "${target}" == *"|"* ]] || [[ "${target}" == *"&"* ]] || [[ "${target}" == *"\`"* ]]; then
		print_error "Invalid target pattern: contains forbidden characters"
		return 1
	fi

	check_docker_available || {
		print_error "Docker is required for this command"
		return 1
	}

	local current_dir
	current_dir=$(pwd)

	# Build command array for safe execution
	local cmd_array
	cmd_array=(
		"docker" "run"
		"-v" "${current_dir}:${current_dir}"
		"-w" "${current_dir}"
		"--rm" "-it"
		"secretlint/secretlint"
		"secretlint" "${target}"
	)

	# Handle extra_args safely
	local extra_array
	extra_array=()
	if [[ -n "${extra_args}" ]]; then
		read -ra extra_array <<<"${extra_args}"
		cmd_array+=("${extra_array[@]}")
	fi

	print_info "Command: ${cmd_array[*]}"
	echo ""

	# Execute using array (safe from injection)
	"${cmd_array[@]}"
}

# Mask secrets in a file
mask_secrets() {
	local input_file="$1"
	local output_file="${2:-${input_file}}"

	print_header "Masking Secrets"

	if [[ -z "${input_file}" ]]; then
		print_error "Input file required"
		print_info "Usage: $0 mask <input-file> [output-file]"
		return 1
	fi

	if [[ ! -f "${input_file}" ]]; then
		print_error "File not found: ${input_file}"
		return 1
	fi

	local cmd
	cmd=$(get_secretlint_cmd)

	print_info "Input: ${input_file}"
	print_info "Output: ${output_file}"

	local mask_exit=0
	${cmd} "${input_file}" --format=mask-result --output="${output_file}" || mask_exit=$?

	if [[ ${mask_exit} -eq 0 ]]; then
		print_success "Secrets masked successfully"
		return 0
	else
		print_error "Failed to mask secrets"
		return 1
	fi
}

# Show status
show_status() {
	print_header "Secretlint Status"
	echo ""

	# Show worktree info if applicable
	if is_git_worktree; then
		local repo_root
		repo_root=$(get_repo_root)
		print_info "Git worktree detected"
		print_info "Main repo: ${repo_root}"
		print_info "Worktree: $(pwd)"
		echo ""
	fi

	# Check installation
	print_info "Installation:"
	check_secretlint_installed || true
	check_docker_available || true
	echo ""

	# Check Node.js
	print_info "Node.js:"
	if command -v node &>/dev/null; then
		local node_v
		node_v=$(node -v)
		print_success "Node.js: ${node_v}"
	else
		print_warning "Node.js: Not installed"
	fi
	echo ""

	# Check configuration
	print_info "Configuration:"
	if [[ -f "${SECRETLINT_CONFIG_FILE}" ]]; then
		print_success "Config file: ${SECRETLINT_CONFIG_FILE}"

		# Count rules
		if command -v jq &>/dev/null; then
			local rules_count
			rules_count=$(jq -r '.rules | length' "${SECRETLINT_CONFIG_FILE}" 2>/dev/null || echo "unknown")
			print_info "Configured rule presets: ${rules_count}"
		fi
	else
		print_warning "Config file: Not found"
		print_info "Run: $0 init"
	fi

	if [[ -f "${SECRETLINT_IGNORE_FILE}" ]]; then
		print_success "Ignore file: ${SECRETLINT_IGNORE_FILE}"
		local ignore_count
		ignore_count=$(grep -cv '^#\|^$' "${SECRETLINT_IGNORE_FILE}" 2>/dev/null || echo "0")
		print_info "Ignore patterns: ${ignore_count}"
	else
		print_warning "Ignore file: Not found"
	fi
	echo ""

	# Validate rule installation
	print_info "Rule Installation:"
	if [[ -f "${SECRETLINT_CONFIG_FILE}" ]]; then
		check_rules_installed "${SECRETLINT_CONFIG_FILE}" &&
			print_success "All configured rules are installed" || true
	else
		print_warning "No config file - cannot validate rules"
	fi
	echo ""

	# Show available rules in preset
	print_info "Recommended Rules (preset-recommend):"
	echo "  - AWS credentials (Access Key, Secret Key, Account ID)"
	echo "  - GCP credentials"
	echo "  - GitHub tokens (PAT, OAuth, App)"
	echo "  - npm tokens"
	echo "  - Private keys (RSA, DSA, EC, OpenSSH)"
	echo "  - Basic auth in URLs"
	echo "  - Slack tokens and webhooks"
	echo "  - SendGrid API keys"
	echo "  - Shopify API keys"
	echo "  - OpenAI API keys"
	echo "  - Anthropic/Claude API keys"
	echo "  - Linear API keys"
	echo "  - 1Password service account tokens"
	echo "  - Database connection strings"
	echo ""

	return 0
}

# Generate SARIF output
generate_sarif() {
	local target="${1:-${DEFAULT_GLOB_PATTERN}}"
	local output_file="${2:-secretlint-results.sarif}"

	print_header "Generating SARIF Output"

	local repo_root
	repo_root=$(get_repo_root)

	# Check if SARIF formatter is installed (CWD, main repo, or global)
	local sarif_installed=false
	if npm list @secretlint/secretlint-formatter-sarif &>/dev/null; then
		sarif_installed=true
	elif [[ "${repo_root}" != "$(pwd)" ]] && npm list --prefix "${repo_root}" @secretlint/secretlint-formatter-sarif &>/dev/null; then
		sarif_installed=true
	fi

	if [[ "${sarif_installed}" != "true" ]]; then
		print_info "Installing SARIF formatter..."
		if [[ "${repo_root}" != "$(pwd)" ]] && [[ -f "${repo_root}/package.json" ]]; then
			npm install --prefix "${repo_root}" --save-dev @secretlint/secretlint-formatter-sarif
		else
			npm install --save-dev @secretlint/secretlint-formatter-sarif
		fi
	fi

	local cmd
	cmd=$(get_secretlint_cmd)

	local sarif_exit=0
	${cmd} "${target}" --format @secretlint/secretlint-formatter-sarif >"${output_file}" || sarif_exit=$?

	if [[ ${sarif_exit} -eq 0 ]]; then
		print_success "SARIF output saved: ${output_file}"
		return 0
	else
		print_error "Failed to generate SARIF output"
		return 1
	fi
}

# Pre-commit hook setup
# Works in both regular repos (.git is a directory) and worktrees (.git is a file)
setup_precommit_hook() {
	print_header "Setting Up Pre-commit Hook"

	# Use git rev-parse to find the real hooks directory (works in worktrees)
	local git_dir
	git_dir=$(get_git_dir)

	if [[ -z "${git_dir}" ]] || ! git rev-parse --git-dir &>/dev/null; then
		print_error "Not a git repository"
		return 1
	fi

	local hook_dir="${git_dir}/hooks"
	local hook_file="${hook_dir}/pre-commit"

	mkdir -p "${hook_dir}"

	# Check if hook already exists
	if [[ -f "${hook_file}" ]]; then
		if grep -q "secretlint" "${hook_file}"; then
			print_warning "Secretlint hook already configured"
			return 0
		else
			print_warning "Pre-commit hook exists. Adding Secretlint..."
			# Append to existing hook
			cat >>"${hook_file}" <<'EOF'

# Secretlint - Secret Detection
FILES=$(git diff --cached --name-only --diff-filter=ACMR | sed 's| |\\ |g')
[ -z "$FILES" ] && exit 0

echo "Running Secretlint..."
echo "$FILES" | xargs npx secretlint
RET=$?
if [ $RET -ne 0 ]; then
    echo "Secretlint found potential secrets. Please review before committing."
    exit 1
fi
EOF
		fi
	else
		# Create new hook
		cat >"${hook_file}" <<'EOF'
#!/bin/sh
# Pre-commit hook with Secretlint integration

# Secretlint - Secret Detection
FILES=$(git diff --cached --name-only --diff-filter=ACMR | sed 's| |\\ |g')
[ -z "$FILES" ] && exit 0

echo "Running Secretlint..."
echo "$FILES" | xargs npx secretlint
RET=$?
if [ $RET -ne 0 ]; then
    echo "Secretlint found potential secrets. Please review before committing."
    exit 1
fi

exit 0
EOF
	fi

	chmod +x "${hook_file}"
	print_success "Pre-commit hook configured: ${hook_file}"

	return 0
}

# Setup with Husky + lint-staged
setup_husky_integration() {
	print_header "Setting Up Husky + lint-staged Integration"

	if [[ ! -f "package.json" ]]; then
		print_error "package.json not found. Initialize npm project first."
		return 1
	fi

	print_info "Installing Husky and lint-staged..."
	npx husky-init 2>/dev/null || npm install husky --save-dev
	npm install lint-staged --save-dev

	# Initialize Husky
	npx husky install

	# Add pre-commit hook
	npx husky add .husky/pre-commit "npx --no-install lint-staged"

	# Update package.json with lint-staged config
	print_info "Adding lint-staged configuration to package.json..."

	if command -v jq &>/dev/null; then
		local tmp_file
		tmp_file=$(mktemp)
		# Ensure temp file is cleaned up on exit; clear trap after successful mv
		trap 'rm -f "${tmp_file}"' EXIT
		jq '. + {"lint-staged": {"*": ["secretlint"]}}' package.json >"${tmp_file}" && mv "${tmp_file}" package.json
		trap - EXIT
		print_success "Added lint-staged configuration"
	else
		print_warning "jq not available. Please add manually to package.json:"
		echo '  "lint-staged": {'
		echo '    "*": ["secretlint"]'
		echo '  }'
	fi

	print_success "Husky + lint-staged configured"

	return 0
}

# Show help
show_help() {
	print_header "Secretlint Helper - Secret Detection Tool"
	echo ""
	echo "Usage: $0 <command> [options]"
	echo ""
	echo "Commands:"
	echo "  install [local|global]   - Install Secretlint and recommended rules"
	echo "  install-rules [rule]     - Install additional rules (pattern|sarif|all|<pkg>)"
	echo "  init                     - Initialize project configuration"
	echo "  scan [target] [format]   - Scan files for secrets"
	echo "  lint [target] [format]   - Alias for scan"
	echo "  quick [target]           - Quick scan via npx (no install)"
	echo "  docker [target]          - Scan via Docker"
	echo "  mask <file> [output]     - Mask secrets in a file"
	echo "  sarif [target] [output]  - Generate SARIF output"
	echo "  hook                     - Setup git pre-commit hook"
	echo "  husky                    - Setup Husky + lint-staged"
	echo "  status                   - Show installation and configuration status"
	echo "  help                     - Show this help message"
	echo ""
	echo "Formats: stylish (default), json, compact, table, sarif, mask-result"
	echo ""
	echo "Examples:"
	echo "  $0 install               # Install locally"
	echo "  $0 init                  # Initialize configuration"
	echo "  $0 scan                  # Scan all files"
	echo "  $0 scan \"src/**/*\"       # Scan specific directory"
	echo "  $0 scan . json           # Output as JSON"
	echo "  $0 quick                 # Quick scan (no install)"
	echo "  $0 docker                # Scan via Docker"
	echo "  $0 mask .env.example     # Mask secrets in file"
	echo "  $0 sarif                 # Generate SARIF for CI/CD"
	echo "  $0 hook                  # Setup pre-commit hook"
	echo ""
	echo "Environment Variables:"
	echo "  None required - Secretlint works offline"
	echo ""
	echo "Detected Secret Types:"
	echo "  - AWS credentials (Access Key, Secret Key)"
	echo "  - GCP service account keys"
	echo "  - GitHub tokens (PAT, OAuth, App, Actions)"
	echo "  - OpenAI/Anthropic API keys"
	echo "  - Private keys (RSA, DSA, EC, OpenSSH)"
	echo "  - Database connection strings"
	echo "  - Slack tokens and webhooks"
	echo "  - npm tokens"
	echo "  - And many more..."
	echo ""
	echo "Reference: https://github.com/secretlint/secretlint"
	return 0
}

# Main function
main() {
	local command="${1:-help}"
	local arg2="${2:-}"
	local arg3="${3:-}"
	local arg4="${4:-}"

	case "${command}" in
	"install")
		install_secretlint "${arg2}"
		;;
	"install-rules")
		install_additional_rules "${arg2}"
		;;
	"init")
		init_secretlint_config
		;;
	"scan" | "lint")
		run_secretlint_scan "${arg2}" "${arg3}" "${arg4}"
		;;
	"quick")
		run_quick_scan "${arg2}"
		;;
	"docker")
		run_docker_scan "${arg2}" "${arg3}"
		;;
	"mask" | "fix")
		mask_secrets "${arg2}" "${arg3}"
		;;
	"sarif")
		generate_sarif "${arg2}" "${arg3}"
		;;
	"hook")
		setup_precommit_hook
		;;
	"husky")
		setup_husky_integration
		;;
	"status")
		show_status
		;;
	"help" | "--help" | "-h")
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND} ${command}"
		echo ""
		show_help
		return 1
		;;
	esac
	return $?
}

# Execute main function with all arguments
main "$@"
