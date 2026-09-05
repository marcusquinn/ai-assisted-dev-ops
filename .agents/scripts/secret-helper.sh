#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# Secret Helper - AI-native secret management with gopass backend
# Keeps secret values out of AI agent context windows via subprocess
# injection and output redaction.
#
# Usage:
#   secret-helper.sh set NAME              # Interactive hidden input -> gopass
#   secret-helper.sh get NAME              # Get secret value (for scripts/piping)
#   secret-helper.sh list                  # List secret names (never values)
#   secret-helper.sh inventory             # Deterministic names-only JSON inventory
#   secret-helper.sh run CMD [ARGS...]     # Inject all secrets, redact output
#   secret-helper.sh NAME [NAME...] -- CMD # Inject specific secrets, redact output
#   secret-helper.sh init                  # Initialize gopass store
#   secret-helper.sh import-credentials    # Migrate from credentials.sh to gopass
#   secret-helper.sh status                # Show backend status
#   secret-helper.sh help                  # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Paths
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"
readonly TENANTS_DIR="$CONFIG_DIR/tenants"
readonly GOPASS_PREFIX="aidevops"
readonly INVENTORY_MAX_NAMES=512
readonly INVENTORY_MAX_NAME_LENGTH=128
readonly REDACTION_INIT_ERROR="Unable to initialize secret output redaction"

# Check if gopass is available and initialized
has_gopass() {
	if ! command -v gopass &>/dev/null; then
		return 1
	fi
	# Check if gopass store is initialized
	if ! gopass ls &>/dev/null; then
		return 1
	fi
	return 0
}

# Check if credentials.sh is a multi-tenant loader (not direct credentials)
# When multi-tenant is active, credentials.sh contains a source command
# pointing to tenants/{tenant}/credentials.sh instead of export lines.
is_tenant_loader() {
	[[ -f "$CREDENTIALS_FILE" ]] && grep -q 'AIDEVOPS_ACTIVE_TENANT=' "$CREDENTIALS_FILE" 2>/dev/null
}

# Resolve actual credential files to process.
# Returns the direct credentials.sh if it contains exports, or all
# tenant credential files if multi-tenant is active.
# Output: one file path per line
resolve_credential_files() {
	if is_tenant_loader; then
		# Multi-tenant: return all tenant credential files
		local tenant_dir
		for tenant_dir in "$TENANTS_DIR"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local cred_file="$tenant_dir/credentials.sh"
			if [[ -f "$cred_file" ]]; then
				echo "$cred_file"
			fi
		done
	elif [[ -f "$CREDENTIALS_FILE" ]]; then
		echo "$CREDENTIALS_FILE"
	fi
	return 0
}

# Get the scalar password value from gopass.
# Used only by cmd_get, which preserves the historical first-line contract.
get_secret_value() {
	local name="$1"
	if has_gopass; then
		gopass show -o "${GOPASS_PREFIX}/${name}" 2>/dev/null || true
	else
		# Fallback to credential files (handles multi-tenant)
		local cred_file
		while IFS= read -r cred_file; do
			[[ -z "$cred_file" ]] && continue
			local value
			# Strip 'export NAME=', strip surrounding double quotes, then unescape
			# \" -> " and \\ -> \ (order matters: unescape \" before \\)
			value=$(grep "^export ${name}=" "$cred_file" 2>/dev/null | head -1 | sed 's/^export [^=]*=//' | sed 's/^"//' | sed 's/"$//' | sed 's/\\"/"/g' | sed 's/\\\\/\\/g')
			if [[ -n "$value" ]]; then
				echo "$value"
				return 0
			fi
		done < <(resolve_credential_files)
	fi
	return 0
}

# Get the complete raw gopass entry for subprocess injection.
# Bash command substitution consistently removes trailing newlines; embedded
# newlines are preserved byte-for-byte and encoded safely by build_secret_env.
get_gopass_entry_value() {
	local secret_path="$1"
	gopass show -n "$secret_path" 2>/dev/null || true
	return 0
}

# Collect all secret values for redaction as NUL-delimited literal data.
collect_secret_values() {
	local -a values=()

	if has_gopass; then
		local secrets
		secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
		while IFS= read -r secret_path; do
			[[ -z "$secret_path" ]] && continue
			local scalar_val=""
			local entry_val=""
			scalar_val=$(gopass show -o "$secret_path" 2>/dev/null || true)
			entry_val=$(get_gopass_entry_value "$secret_path")
			if [[ -n "$scalar_val" && ${#scalar_val} -ge 4 ]]; then
				values+=("$scalar_val")
			fi
			if [[ -n "$entry_val" && ${#entry_val} -ge 4 && "$entry_val" != "$scalar_val" ]]; then
				values+=("$entry_val")
			fi
		done <<<"$secrets"
	fi

	# Also collect from credential files as fallback (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+[A-Z_][A-Z0-9_]*= ]]; then
				local val="${line#*=}"
				val="${val#\"}"
				val="${val%\"}"
				val="${val#\'}"
				val="${val%\'}"
				if [[ -n "$val" && ${#val} -ge 4 ]]; then
					values+=("$val")
				fi
			fi
		done <"$cred_file"
	done < <(resolve_credential_files)

	if [[ ${#values[@]} -gt 0 ]]; then
		printf '%s\0' "${values[@]}"
	fi
	return 0
}

# Redact secret values from a stream
# Reads stdin, replaces any secret value with [REDACTED]
redact_stream() {
	local values_file
	local previous_umask
	previous_umask=$(umask)
	umask 077
	if ! values_file=$(mktemp); then
		umask "$previous_umask"
		print_error "$REDACTION_INIT_ERROR" >&2
		return 1
	fi
	umask "$previous_umask"
	trap 'rm -f "$values_file"' RETURN

	if ! collect_secret_values >"$values_file"; then
		print_error "$REDACTION_INIT_ERROR" >&2
		return 1
	fi

	if [[ ! -s "$values_file" ]]; then
		# No secrets to redact, pass through
		cat
		return 0
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		print_error "$REDACTION_INIT_ERROR" >&2
		return 1
	fi

	local exit_code=0
	python3 -c '
import sys

with open(sys.argv[1], "rb") as values_handle:
    secret_values = sorted(
        {value for value in values_handle.read().split(b"\0") if len(value) >= 4},
        key=len,
        reverse=True,
    )

if not secret_values:
    raise SystemExit("redaction values were empty")

marker = b"[REDACTED]"
maximum_length = len(secret_values[0])
output = sys.stdout.buffer
pending = b""

def redact_available(data, final=False):
    keep = 0 if final else maximum_length - 1
    pieces = []
    while len(data) > keep:
        match = next((value for value in secret_values if data.startswith(value)), None)
        if match is not None:
            pieces.append(marker)
            data = data[len(match):]
        else:
            pieces.append(data[:1])
            data = data[1:]
        if len(pieces) >= 8192:
            output.write(b"".join(pieces))
            output.flush()
            pieces.clear()
    if pieces:
        output.write(b"".join(pieces))
        output.flush()
    return data

while True:
    chunk = sys.stdin.buffer.read(65536)
    if not chunk:
        break
    pending = redact_available(pending + chunk)

redact_available(pending, final=True)
' "$values_file" || exit_code=$?

	return "$exit_code"
}

# Return success when a secret name was already emitted.
secret_env_name_emitted() {
	local expected_name="$1"
	shift
	local emitted_name=""
	for emitted_name in "$@"; do
		[[ "$emitted_name" == "$expected_name" ]] && return 0
	done
	return 1
}

# Emit one NUL-delimited environment record. Environment values cannot contain
# NUL bytes, making NUL a safe record delimiter while preserving newlines.
emit_secret_env_record() {
	local name="$1"
	local value="$2"
	printf '%s=%s\0' "$name" "$value"
	return 0
}

# Build a NUL-delimited environment from gopass secrets.
build_secret_env() {
	local -a specific_names=("$@")
	local -a emitted_names=()

	if has_gopass; then
		if [[ ${#specific_names[@]} -gt 0 ]]; then
			# Inject only specific secrets
			for name in "${specific_names[@]}"; do
				local val
				val=$(get_gopass_entry_value "${GOPASS_PREFIX}/${name}")
				if [[ -n "$val" ]]; then
					emit_secret_env_record "$name" "$val"
					emitted_names+=("$name")
				fi
			done
		else
			# Inject all secrets
			local secrets
			secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				local name="${secret_path#"${GOPASS_PREFIX}"/}"
				local val
				val=$(get_gopass_entry_value "$secret_path")
				if [[ -n "$val" ]]; then
					emit_secret_env_record "$name" "$val"
					emitted_names+=("$name")
				fi
			done <<<"$secrets"
		fi
	fi

	# Also load from credential files as fallback/supplement (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
				local name="${BASH_REMATCH[1]}"
				local val="${BASH_REMATCH[2]}"
				val="${val#\"}"
				val="${val%\"}"
				# Only add if not already set by gopass
				if ! secret_env_name_emitted "$name" "${emitted_names[@]}"; then
					emit_secret_env_record "$name" "$val"
					emitted_names+=("$name")
				fi
			fi
		done <"$cred_file"
	done < <(resolve_credential_files)

	return 0
}

# --- Commands ---

# Read and validate a secret value from stdin/tty
read_secret_input() {
	local name="$1"
	local value=""

	# CRITICAL: All user-facing messages MUST go to stderr (>&2), not stdout.
	# This function's stdout is captured by $() in cmd_set — any print_info
	# or echo to stdout gets stored as part of the secret value. This was the
	# root cause of GH#4939: prompt text was stored in gopass instead of the
	# actual secret.
	if [[ -t 0 ]]; then
		print_info "Enter secret value for $name (input hidden):" >&2
		print_info "Paste only the secret value, then press Enter" >&2
		IFS= read -rs value || true
		echo "" >&2
	else
		IFS= read -r value || true
	fi

	value="${value%$'\r'}"

	if [[ -z "$value" ]]; then
		print_error "No secret value received for $name" >&2
		print_info "Run again and paste only the secret value" >&2
		return 1
	fi

	if [[ "$value" =~ ^[[:space:]]*aidevops[[:space:]]+secret[[:space:]]+set([[:space:]]|$) ]]; then
		print_error "Input for $name looks like a command, not a secret value" >&2
		print_info "Paste the secret value itself, not 'aidevops secret set ...'" >&2
		return 1
	fi

	printf '%s' "$value"
	return 0
}

# Acquire an exclusive directory lock for fallback credential mutations.
# mkdir is atomic on local filesystems and portable across the supported shells.
acquire_credentials_lock() {
	local lock_dir="${CREDENTIALS_FILE}.lock"
	local attempts=0

	while ! mkdir "$lock_dir" 2>/dev/null; do
		((++attempts))
		if [[ "$attempts" -ge 300 ]]; then
			print_error "Timed out waiting to update credentials.sh"
			return 1
		fi
		sleep 0.1
	done

	printf '%s' "$lock_dir"
	return 0
}

# Release a lock acquired by acquire_credentials_lock.
release_credentials_lock() {
	local lock_dir="$1"
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

# Atomically replace one fallback credential while preserving every other entry.
update_fallback_credential() {
	local name="$1"
	local escaped_value="$2"
	local filter_status=0
	local lock_dir=""
	local tmp_file=""
	local previous_umask=""

	# The lock lives beside the credentials file, so its parent must exist before
	# acquisition. File creation remains inside the lock to avoid truncation races.
	if ! mkdir -p "$CONFIG_DIR" || ! chmod 700 "$CONFIG_DIR"; then
		print_error "Unable to prepare credentials directory"
		return 1
	fi

	if ! lock_dir=$(acquire_credentials_lock); then
		return 1
	fi

	if ! ensure_credentials_file "$CREDENTIALS_FILE"; then
		release_credentials_lock "$lock_dir"
		return 1
	fi

	previous_umask=$(umask)
	umask 077
	if ! tmp_file=$(mktemp "${CREDENTIALS_FILE}.tmp.XXXXXX"); then
		umask "$previous_umask"
		release_credentials_lock "$lock_dir"
		print_error "Unable to create temporary credentials file"
		return 1
	fi
	umask "$previous_umask"

	grep -v "^export ${name}=" "$CREDENTIALS_FILE" >"$tmp_file" || filter_status=$?
	if [[ "$filter_status" -gt 1 ]] ||
		! printf 'export %s="%s"\n' "$name" "$escaped_value" >>"$tmp_file" ||
		! chmod 600 "$tmp_file" ||
		! mv -f "$tmp_file" "$CREDENTIALS_FILE"; then
		rm -f "$tmp_file" || true
		release_credentials_lock "$lock_dir"
		print_error "Unable to update credentials.sh"
		return 1
	fi

	release_credentials_lock "$lock_dir"
	return 0
}

# Initialize gopass store for aidevops
cmd_init() {
	if ! command -v gopass &>/dev/null; then
		print_info "gopass not found. Installing..."
		if command -v brew &>/dev/null; then
			brew install gopass
		elif command -v apt-get &>/dev/null; then
			sudo apt-get install -y gopass
		elif command -v pacman &>/dev/null; then
			sudo pacman -S gopass
		else
			print_error "Cannot auto-install gopass. Install manually: https://github.com/gopasspw/gopass#installation"
			return 1
		fi
	fi

	if ! gopass ls &>/dev/null; then
		print_info "Initializing gopass store..."
		gopass setup
	fi

	# Create aidevops subfolder if it doesn't exist
	if ! gopass ls "${GOPASS_PREFIX}/" &>/dev/null; then
		print_info "Creating ${GOPASS_PREFIX}/ prefix in gopass store"
		# gopass creates folders implicitly when secrets are added
	fi

	print_success "gopass initialized for aidevops"
	print_info "Store secrets: aidevops secret set SECRET_NAME"
	print_info "Import existing: aidevops secret import-credentials"
	return 0
}

# Set a secret (interactive hidden input)
cmd_set() {
	local name="$1"

	if [[ -z "$name" ]]; then
		print_error "Usage: aidevops secret set SECRET_NAME"
		return 1
	fi

	# Normalize to uppercase
	name=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')

	print_info "Setting secret: $name"
	print_warning "WARNING: Never paste secret values into AI chat"
	print_warning "Run this command in your terminal and enter the value at the hidden prompt"
	echo ""
	echo "  1) When prompted, paste ONLY the secret value"
	echo "  2) Do NOT paste the command, key name, or an export line"
	echo "  3) Input is hidden; press Enter when done"
	echo ""

	local value
	if ! value=$(read_secret_input "$name"); then
		return 1
	fi

	if has_gopass; then
		local gopass_output
		if ! gopass_output=$(printf '%s' "$value" | gopass insert --force "${GOPASS_PREFIX}/${name}" 2>&1); then
			if [[ "$gopass_output" == *"BLOCKED by canonical Git guard"* ]]; then
				print_error "Failed to store $name in gopass because the canonical Git guard blocked the password-store update"
				printf '  %s\n' "$gopass_output" >&2
			elif [[ "$gopass_output" == *"GPG"* || "$gopass_output" == *"gpg"* ]]; then
				print_error "Failed to store $name in gopass (GPG error)"
			elif [[ "$gopass_output" == *"not initialized"* ]]; then
				print_error "Failed to store $name in gopass (store not initialized)"
			else
				print_error "Failed to store $name in gopass. Error from gopass:"
				echo "${gopass_output}" | sed 's/^/  /'
			fi
			return 1
		fi
		print_success "Stored $name in gopass"
	else
		print_warning "gopass not available, falling back to credentials.sh"

		# Escape backslashes then double quotes so the value can be safely embedded
		# in a double-quoted shell assignment.  get_secret_value() strips the
		# surrounding double quotes, so this round-trips correctly.
		local escaped_value="${value//\\/\\\\}"
		escaped_value="${escaped_value//\"/\\\"}"
		if ! update_fallback_credential "$name" "$escaped_value"; then
			return 1
		fi
		print_success "Stored $name in credentials.sh"
		print_info "Recommend: aidevops secret init (to enable encrypted storage)"
		print_info "Do not run concurrent refreshes for the same rotating refresh token"
	fi
	print_info "Verify key name only: aidevops secret list"

	return 0
}

# Get a secret value by name (for programmatic/script use)
# Outputs raw value to stdout for piping into commands
cmd_get() {
	local name="${1:-}"

	if [[ -z "$name" ]]; then
		print_error "Usage: aidevops secret get SECRET_NAME"
		return 1
	fi

	# Normalize to uppercase
	name=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')

	local value
	value=$(get_secret_value "$name")

	if [[ -z "$value" ]]; then
		print_error "Secret not found: $name" >&2
		return 1
	fi

	printf '%s' "$value"
	return 0
}

# List secret names (NEVER values)
cmd_list() {
	local has_secrets=false

	if has_gopass; then
		local secrets
		secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
		if [[ -n "$secrets" ]]; then
			print_info "Secrets in gopass (${GOPASS_PREFIX}/):"
			echo ""
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				local name="${secret_path#"${GOPASS_PREFIX}"/}"
				echo "  $name"
				has_secrets=true
			done <<<"$secrets"
			echo ""
		fi
	fi

	if [[ -f "$CREDENTIALS_FILE" ]]; then
		local cred_keys
		cred_keys=$(grep "^export " "$CREDENTIALS_FILE" 2>/dev/null | sed 's/=.*//' | sed 's/export //' | sort || true)
		if [[ -n "$cred_keys" ]]; then
			print_info "Secrets in credentials.sh:"
			echo ""
			while IFS= read -r key; do
				[[ -z "$key" ]] && continue
				echo "  $key"
				has_secrets=true
			done <<<"$cred_keys"
			echo ""
		fi
	fi

	if [[ "$has_secrets" == "false" ]]; then
		print_info "No secrets configured"
		print_info "Add secrets: aidevops secret set SECRET_NAME"
	fi

	return 0
}

# Emit validated secret-name metadata without invoking any value-reading command.
# A subshell keeps the EXIT trap and its local paths scoped to this command.
cmd_inventory() (
	local gopass_status="missing"
	local credentials_status="missing"
	local names_file=""
	local sorted_file=""
	local count=0

	names_file=$(mktemp) || return 1
	sorted_file="${names_file}.sorted"
	trap 'rm -f "${names_file:-}" "${sorted_file:-}"' EXIT

	if command -v gopass &>/dev/null; then
		gopass_status="error"
		local listing=""
		if listing=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null); then
			gopass_status="available"
			local secret_path=""
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				case "$secret_path" in
				"${GOPASS_PREFIX}/"*) inventory_add_name "${secret_path#"${GOPASS_PREFIX}/"}" "$names_file" || return 1 ;;
				*)
					print_error "Invalid gopass inventory path" >&2
					return 1
					;;
				esac
			done <<<"$listing"
		fi
	fi

	local credential_file=""
	while IFS= read -r credential_file; do
		[[ -z "$credential_file" ]] && continue
		credentials_status="error"
		if [[ -L "$credential_file" ]] || [[ ! -f "$credential_file" ]]; then
			print_error "Credentials inventory source must be a regular non-symlink file" >&2
			return 1
		fi
		local permissions=""
		permissions=$(stat -f '%Lp' "$credential_file" 2>/dev/null || stat -c '%a' "$credential_file" 2>/dev/null || true)
		if [[ ! "$permissions" =~ ^[046]00$ ]]; then
			print_error "Credentials inventory source must be owner-only" >&2
			return 1
		fi
		credentials_status="available"
		local line=""
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+([A-Z][A-Z0-9_]*)= ]]; then
				inventory_add_name "${BASH_REMATCH[1]}" "$names_file" || return 1
			fi
		done <"$credential_file"
	done < <(resolve_credential_files)

	sort -u "$names_file" >"$sorted_file"
	mv "$sorted_file" "$names_file"
	count=$(wc -l <"$names_file" | tr -d ' ')
	if [[ "$count" -gt "$INVENTORY_MAX_NAMES" ]]; then
		print_error "Secret inventory exceeds ${INVENTORY_MAX_NAMES} names" >&2
		return 1
	fi

	printf '{"version":1,"backends":{"gopass":"%s","credentials":"%s"},"secrets":[' "$gopass_status" "$credentials_status"
	local separator=""
	local name=""
	while IFS= read -r name; do
		[[ -z "$name" ]] && continue
		printf '%s{"name":"%s","status":"configured"}' "$separator" "$name"
		separator=","
	done <"$names_file"
	printf ']}\n'

	return 0
)

inventory_add_name() {
	local name="$1"
	local output_file="$2"

	if [[ ${#name} -gt "$INVENTORY_MAX_NAME_LENGTH" ]] || [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
		print_error "Invalid secret inventory name" >&2
		return 1
	fi
	printf '%s\n' "$name" >>"$output_file"
	return 0
}

# Run a command with secrets injected and output redacted
cmd_run() {
	local -a cmd_args=("$@")

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		print_error "Usage: aidevops secret run COMMAND [ARGS...]"
		return 1
	fi

	# Build environment in temp file with trap cleanup for security
	local env_file
	env_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$env_file'" EXIT

	build_secret_env >"$env_file"

	# Execute command with secrets in environment, redact output
	local exit_code=0
	(
		# Load secrets into subprocess environment
		while IFS='=' read -r -d '' key val; do
			[[ -z "$key" ]] && continue
			export "$key=$val"
		done <"$env_file"

		# Execute the command
		"${cmd_args[@]}"
	) 2>&1 | redact_stream || exit_code=$?

	# Clean up (also handled by trap on abnormal exit)
	rm -f "$env_file"
	trap - EXIT

	return "$exit_code"
}

# Run with specific secrets: secret NAME1 NAME2 -- command args
cmd_run_specific() {
	local -a secret_names=()
	local -a cmd_args=()
	local found_separator=false

	for arg in "$@"; do
		if [[ "$arg" == "--" ]]; then
			found_separator=true
			continue
		fi
		if [[ "$found_separator" == "true" ]]; then
			cmd_args+=("$arg")
		else
			secret_names+=("$arg")
		fi
	done

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		print_error "Usage: aidevops secret NAME [NAME...] -- COMMAND [ARGS...]"
		return 1
	fi

	# Build environment with specific secrets only, trap cleanup for security
	local env_file
	env_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$env_file'" EXIT

	build_secret_env "${secret_names[@]}" >"$env_file"

	# Execute command with secrets in environment, redact output
	local exit_code=0
	(
		while IFS='=' read -r -d '' key val; do
			[[ -z "$key" ]] && continue
			export "$key=$val"
		done <"$env_file"

		"${cmd_args[@]}"
	) 2>&1 | redact_stream || exit_code=$?

	rm -f "$env_file"
	trap - EXIT

	return "$exit_code"
}

# Import a single credential file to gopass, with optional tenant prefix
# Args: $1=file_path, $2=tenant_name (empty for non-tenant)
# Sets: imported, skipped (caller's variables via nameref)
_import_credential_file() {
	local file="$1"
	local tenant="$2"

	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
			local name="${BASH_REMATCH[1]}"
			local val="${BASH_REMATCH[2]}"
			val="${val#\"}"
			val="${val%\"}"
			val="${val#\'}"
			val="${val%\'}"

			# Skip empty/placeholder values
			if [[ -z "$val" || "$val" == "YOUR_"* || "$val" == "CHANGE_ME"* ]]; then
				((++skipped))
				continue
			fi

			# Build gopass path: aidevops/NAME or aidevops/tenants/TENANT/NAME
			local gopass_path="${GOPASS_PREFIX}/${name}"
			if [[ -n "$tenant" ]]; then
				gopass_path="${GOPASS_PREFIX}/tenants/${tenant}/${name}"
			fi

			# Check if already in gopass
			if gopass show -o "$gopass_path" &>/dev/null; then
				print_info "Skipping $name (already in gopass${tenant:+ [$tenant]})"
				((++skipped))
				continue
			fi

			# Import to gopass
			echo "$val" | gopass insert --force "$gopass_path"
			((++imported))
			print_success "Imported $name${tenant:+ (tenant: $tenant)}"
		fi
	done <"$file"

	return 0
}

# Import credentials from credentials.sh (or tenant files) to gopass
cmd_import_credentials() {
	if ! has_gopass; then
		print_error "gopass not initialized. Run: aidevops secret init"
		return 1
	fi

	if [[ ! -f "$CREDENTIALS_FILE" ]] && [[ ! -d "$TENANTS_DIR" ]]; then
		print_info "No credentials.sh found to import"
		return 0
	fi

	local imported=0
	local skipped=0

	if is_tenant_loader; then
		# Multi-tenant mode: import from each tenant's credential file
		print_info "Multi-tenant credentials detected"
		local tenant_dir
		for tenant_dir in "$TENANTS_DIR"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local tenant_name
			tenant_name=$(basename "$tenant_dir")
			local cred_file="$tenant_dir/credentials.sh"
			if [[ -f "$cred_file" ]]; then
				print_info "Importing tenant: $tenant_name"
				_import_credential_file "$cred_file" "$tenant_name"
			fi
		done
	elif [[ -f "$CREDENTIALS_FILE" ]]; then
		# Single-mode: import directly from credentials.sh
		_import_credential_file "$CREDENTIALS_FILE" ""
	fi

	print_success "Imported $imported secret(s), skipped $skipped"

	if [[ $imported -gt 0 ]]; then
		print_info "Verify with: aidevops secret list"
		print_info "You can now remove plaintext values from credentials.sh"
	fi

	return 0
}

# Show backend status
cmd_status() {
	echo ""
	print_info "Secret Management Status"
	echo "========================="
	echo ""

	# gopass status
	if command -v gopass &>/dev/null; then
		local gopass_version
		gopass_version=$(gopass version 2>/dev/null | head -1 || echo "unknown")
		echo -e "  gopass:       ${GREEN}installed${NC} ($gopass_version)"

		if gopass ls &>/dev/null; then
			local secret_count
			secret_count=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null | wc -l | tr -d ' ')
			echo -e "  gopass store: ${GREEN}initialized${NC} ($secret_count secrets in ${GOPASS_PREFIX}/)"
		else
			echo -e "  gopass store: ${YELLOW}not initialized${NC}"
			echo -e "                Run: aidevops secret init"
		fi
	else
		echo -e "  gopass:       ${YELLOW}not installed${NC}"
		echo -e "                Install: brew install gopass"
	fi

	# GPG status
	if command -v gpg &>/dev/null; then
		local gpg_keys
		gpg_keys=$(gpg --list-secret-keys 2>/dev/null | safe_grep_count "^sec")
		echo -e "  GPG:          ${GREEN}installed${NC} ($gpg_keys secret key(s))"
	else
		echo -e "  GPG:          ${YELLOW}not installed${NC}"
	fi

	# credentials.sh status
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		local key_count
		key_count=$(safe_grep_count "^export " "$CREDENTIALS_FILE" 2>/dev/null)
		echo -e "  credentials:  ${GREEN}$key_count key(s)${NC} in $CREDENTIALS_FILE"
	else
		echo -e "  credentials:  ${DIM}no file${NC}"
	fi

	echo ""
	return 0
}

# Show help
cmd_help() {
	echo ""
	print_info "AI DevOps - Secret Management"
	echo ""
	echo "  Manage secrets with gopass (encrypted) or credentials.sh (plaintext fallback)."
	echo "  Secret values are NEVER exposed to AI agent context windows."
	echo ""
	print_info "Commands:"
	echo ""
	echo "  init                              Initialize gopass store"
	echo "  set <NAME>                        Store a secret (interactive hidden input)"
	echo "  get <NAME>                        Get a secret value (for scripts/piping)"
	echo "  list                              List secret names (never values)"
	echo "  inventory                         Names-only structured local inventory"
	echo "  status                            Show backend status"
	echo ""
	echo "  run CMD [ARGS...]                 Run command with all secrets injected"
	echo "  NAME [NAME...] -- CMD [ARGS...]   Run command with specific secrets"
	echo "  import-credentials                Import from credentials.sh to gopass"
	echo ""
	print_info "Examples:"
	echo ""
	echo "  # WARNING: Never paste secret values into AI chat"
	echo "  # Run secret set in your terminal and enter the value at hidden prompt"
	echo ""
	echo "  # Store a secret (value entered at terminal, hidden)"
	echo "  aidevops secret set STRIPE_KEY"
	echo ""
	echo "  # Secret set flow"
	echo "  # 1) Run set command"
	echo "  # 2) At hidden prompt, paste only the secret value"
	echo "  # 3) Press Enter"
	echo "  # 4) Verify key name only"
	echo "  aidevops secret list"
	echo ""
	echo "  # Run a command with secrets injected (output redacted)"
	echo "  aidevops secret run curl -H 'Authorization: Bearer \$STRIPE_KEY' https://api.stripe.com/v1/charges"
	echo ""
	echo "  # Inject specific secrets only"
	echo "  aidevops secret GITHUB_TOKEN -- gh api /user"
	echo ""
	echo "  # Import existing credentials to gopass"
	echo "  aidevops secret import-credentials"
	echo ""
	print_info "Security:"
	echo ""
	echo "  - Secret values are injected via subprocess environment (never in agent context)"
	echo "  - All command output is automatically redacted (secret values -> [REDACTED])"
	echo "  - gopass encrypts secrets at rest with GPG"
	echo "  - credentials.sh is plaintext fallback (chmod 600)"
	echo ""
	return 0
}

# Main dispatch
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	init)
		cmd_init "$@"
		;;
	set)
		cmd_set "$@"
		;;
	get)
		cmd_get "$@"
		;;
	list | ls)
		cmd_list "$@"
		;;
	inventory)
		cmd_inventory "$@"
		;;
	run)
		cmd_run "$@"
		;;
	import-credentials | import)
		cmd_import_credentials "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		# Check if it looks like "NAME [NAME...] -- CMD"
		# (specific secret injection pattern)
		if [[ "$command" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
			cmd_run_specific "$command" "$@"
		else
			print_error "Unknown command: $command"
			echo ""
			cmd_help
			return 1
		fi
		;;
	esac

	return 0
}

main "$@"
