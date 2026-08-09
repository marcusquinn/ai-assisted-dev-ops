#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# signing-setup.sh — Configure and verify SSH commit signing for git.
# Nice and straightforward setup for cryptographic provenance on commits.
# Usage: signing-setup.sh [setup|headless-setup|agent-start|check|verify-tag|verify-update]
# Run setup/headless-setup directly in your terminal (not via AI session).
# -----------------------------------------------------------------------------

set -euo pipefail

readonly SSH_KEY_DEFAULT="$HOME/.ssh/id_ed25519.pub"
readonly SSH_KEY_HEADLESS="$HOME/.ssh/id_ed25519_signing"
readonly SSH_KEY_HEADLESS_PUB="$HOME/.ssh/id_ed25519_signing.pub"
readonly ALLOWED_SIGNERS_FILE="$HOME/.ssh/allowed_signers"
readonly SSH_AGENT_ENV="$HOME/.ssh/agent.env"

# Trusted maintainer key for aidevops framework supply chain verification.
# This fingerprint is checked during `aidevops update` to verify that pulled
# code was signed by the framework maintainer. Good stuff for provenance.
readonly TRUSTED_FINGERPRINT="SHA256:9zMR/PCmVheKd6gWRChrho7CzGkzomk/8Qm7DCpqTGQ"
readonly TRUSTED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnXVft9/hT5P2dIICJMMmXeg6HUnKGCvR4VzkKpyJza marcus@marcusquinn.com"
readonly TRUSTED_EMAIL="6428977+marcusquinn@users.noreply.github.com"

_print_info() {
	local msg="$1"
	echo "[INFO] $msg"
	return 0
}

_print_ok() {
	local msg="$1"
	echo "[OK] $msg"
	return 0
}

_print_warn() {
	local msg="$1"
	echo "[WARN] $msg"
	return 0
}

_print_error() {
	local msg="$1"
	echo "[ERROR] $msg"
	return 0
}

_source_signing_agent_env() {
	[[ -r "$SSH_AGENT_ENV" ]] || return 0
	# shellcheck source=/dev/null
	. "$SSH_AGENT_ENV" >/dev/null 2>&1 || true
	return 0
}

_headless_signing_key_loaded() {
	[[ -r "$SSH_KEY_HEADLESS_PUB" ]] || return 1
	local expected_key=""
	expected_key=$(<"$SSH_KEY_HEADLESS_PUB") || return 1
	[[ -n "$expected_key" ]] || return 1
	ssh-add -L 2>/dev/null | grep -qxF "$expected_key"
	return $?
}

# Check current signing setup
cmd_check() {
	echo "Checking git commit signing configuration..."
	echo ""

	local gpg_format signing_key commit_sign tag_sign
	gpg_format=$(git config --global gpg.format 2>/dev/null || echo "not set")
	signing_key=$(git config --global user.signingkey 2>/dev/null || echo "not set")
	commit_sign=$(git config --global commit.gpgsign 2>/dev/null || echo "not set")
	tag_sign=$(git config --global tag.gpgsign 2>/dev/null || echo "not set")

	echo "  gpg.format:      $gpg_format"
	echo "  user.signingkey: $signing_key"
	echo "  commit.gpgsign:  $commit_sign"
	echo "  tag.gpgsign:     $tag_sign"
	echo ""

	if [[ "$gpg_format" == "ssh" && "$signing_key" != "not set" && "$commit_sign" == "true" ]]; then
		_print_ok "SSH commit signing is configured"
		if [[ "$signing_key" == "$SSH_KEY_HEADLESS_PUB" ]]; then
			_print_warn "Default Git signing uses the passphrase-less headless key"
			echo "Run 'aidevops signing setup' to restore the passphrase-protected interactive key; workers use the headless key through process-scoped config."
		else
			_print_ok "Default Git signing key is separate from the headless worker key"
		fi

		if [[ -f "$ALLOWED_SIGNERS_FILE" ]]; then
			_print_ok "Allowed signers file exists: $ALLOWED_SIGNERS_FILE"
		else
			_print_warn "No allowed_signers file — signature verification cannot work locally"
		fi
	else
		_print_warn "SSH commit signing is not fully configured"
		echo ""
		echo "Run: aidevops signing setup"
	fi

	echo ""
	echo "Headless worker signing key:"
	if [[ -f "$SSH_KEY_HEADLESS" ]]; then
		_print_ok "Passphrase-less signing key exists: $SSH_KEY_HEADLESS"
		_source_signing_agent_env
		# Check if key is loaded in ssh-agent
		if _headless_signing_key_loaded; then
			_print_ok "Key is loaded in ssh-agent"
		else
			_print_warn "Key not loaded in ssh-agent — run: aidevops signing agent-start"
		fi
	else
		_print_warn "No headless signing key — run: aidevops signing headless-setup"
	fi
	return 0
}

# Configure SSH commit signing
cmd_setup() {
	echo "Setting up SSH commit signing..."
	echo ""

	# Detect SSH key
	local ssh_key="$SSH_KEY_DEFAULT"
	if [[ ! -f "$ssh_key" ]]; then
		_print_error "No SSH key found at $ssh_key"
		echo "Generate one: ssh-keygen -t ed25519 -C \"your@email.com\""
		return 1
	fi

	_print_info "Using SSH key: $ssh_key"
	echo ""

	# Get git email for allowed_signers
	local git_email
	git_email=$(git config --global user.email 2>/dev/null || echo "")
	if [[ -z "$git_email" ]]; then
		_print_error "No git user.email configured"
		echo "Set it: git config --global user.email \"your@email.com\""
		return 1
	fi

	# Configure git to use SSH signing
	git config --global gpg.format ssh
	git config --global user.signingkey "$ssh_key"
	git config --global commit.gpgsign true
	git config --global tag.gpgsign true
	_print_ok "Git configured for SSH commit signing"

	# Create allowed_signers file for verification
	local key_content
	key_content=$(cat "$ssh_key")
	if [[ ! -f "$ALLOWED_SIGNERS_FILE" ]] || ! grep -q "$git_email" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$git_email $key_content" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added $git_email to $ALLOWED_SIGNERS_FILE"
	else
		_print_info "Email already in allowed_signers file"
	fi

	# Also add the aidevops trusted key so users can verify framework updates
	if ! grep -q "$TRUSTED_EMAIL" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$TRUSTED_EMAIL $TRUSTED_KEY" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added aidevops maintainer key to allowed_signers"
	fi

	git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
	_print_ok "Allowed signers file configured"

	echo ""
	_print_ok "Done. All future commits and tags will be signed."
	echo ""
	echo "Next steps:"
	echo "  1. Upload your SSH key to GitHub: Settings > SSH and GPG keys > New SSH signing key"
	echo "     Key: $(cat "$ssh_key")"
	echo "  2. Commits will show as 'Verified' on GitHub"
	echo ""
	echo "  Verify: git log --show-signature -1"
	return 0
}

# Generate a passphrase-less SSH signing key for headless workers.
# This key is separate from the user's primary SSH key and has no passphrase,
# so headless workers (pulse, cron, CI) can sign commits without interactive input.
#
# Security model: the key is scoped to signing only (no SSH auth use), stored at
# ~/.ssh/id_ed25519_signing, and must be registered on GitHub as a signing key
# (not an auth key). Passphrase-less is intentional — headless workers cannot
# prompt for a passphrase.
#
# Usage: signing-setup.sh headless-setup
cmd_headless_setup() {
	echo "Setting up passphrase-less SSH signing key for headless workers..."
	echo ""

	# Get git email for allowed_signers
	local git_email
	git_email=$(git config --global user.email 2>/dev/null || echo "")
	if [[ -z "$git_email" ]]; then
		_print_error "No git user.email configured"
		echo "Set it: git config --global user.email \"your@email.com\""
		return 1
	fi

	# Generate key if it doesn't exist
	if [[ -f "$SSH_KEY_HEADLESS" ]]; then
		_print_info "Headless signing key already exists: $SSH_KEY_HEADLESS"
	else
		_print_info "Generating passphrase-less Ed25519 signing key..."
		ssh-keygen -t ed25519 -C "aidevops-headless-signing" -f "$SSH_KEY_HEADLESS" -N "" -q
		_print_ok "Generated: $SSH_KEY_HEADLESS"
	fi

	# Do not replace the user's interactive signing key. Headless runtimes inject
	# this dedicated key through process-scoped Git configuration.
	local default_signing_key=""
	default_signing_key=$(git config --global user.signingkey 2>/dev/null || true)
	if [[ "$default_signing_key" == "$SSH_KEY_HEADLESS_PUB" ]]; then
		_print_warn "Default Git signing still points to the headless key"
		echo "After updating aidevops, run 'aidevops signing setup' to restore the passphrase-protected interactive key."
	else
		_print_ok "Preserved default interactive Git signing key"
	fi
	_print_ok "Headless runtimes will apply the dedicated key with process-scoped Git config"

	# Add to allowed_signers
	local key_content
	key_content=$(cat "$SSH_KEY_HEADLESS_PUB")
	if [[ ! -f "$ALLOWED_SIGNERS_FILE" ]] || ! grep -qF "$git_email" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$git_email $key_content" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added $git_email to $ALLOWED_SIGNERS_FILE"
	else
		# Update entry if key changed (replace old line for this email)
		if ! grep -qF "$key_content" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
			# Remove old entry and add new one
			local tmp_file
			tmp_file=$(mktemp)
			grep -vF "$git_email" "$ALLOWED_SIGNERS_FILE" >"$tmp_file" 2>/dev/null || true
			echo "$git_email $key_content" >>"$tmp_file"
			mv "$tmp_file" "$ALLOWED_SIGNERS_FILE"
			_print_ok "Updated $git_email entry in $ALLOWED_SIGNERS_FILE"
		else
			_print_info "Email already in allowed_signers with correct key"
		fi
	fi

	# Also add the aidevops trusted key so users can verify framework updates
	if ! grep -qF "$TRUSTED_EMAIL" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$TRUSTED_EMAIL $TRUSTED_KEY" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added aidevops maintainer key to allowed_signers"
	fi

	git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
	_print_ok "Allowed signers file configured"

	# Start ssh-agent and load the key
	cmd_agent_start

	echo ""
	_print_ok "Headless signing key ready."
	echo ""
	echo "Next steps:"
	echo "  1. Upload the signing key to GitHub (as a SIGNING key, not auth key):"
	echo "     Settings > SSH and GPG keys > New SSH signing key"
	echo "     Key: $(cat "$SSH_KEY_HEADLESS_PUB")"
	echo "  2. Add agent-start to your shell profile or cron environment:"
	echo "     aidevops signing agent-start"
	echo "  3. Verify both key roles: aidevops signing check"
	echo "  4. Guide: ~/.aidevops/agents/reference/git-signing.md"
	return 0
}

# Start ssh-agent and load the headless signing key.
# Persists agent socket/PID to ~/.ssh/agent.env so headless workers can source it.
# Safe to call multiple times — reuses existing agent if still running.
#
# Usage: signing-setup.sh agent-start
cmd_agent_start() {
	echo "Starting ssh-agent for headless signing..."

	if [[ ! -f "$SSH_KEY_HEADLESS" ]]; then
		_print_error "No headless signing key found at $SSH_KEY_HEADLESS"
		echo "Run: aidevops signing headless-setup"
		return 1
	fi

	# Check if a valid agent is already running
	local agent_running=false
	if [[ -f "$SSH_AGENT_ENV" ]]; then
		# shellcheck source=/dev/null
		. "$SSH_AGENT_ENV" >/dev/null 2>&1 || true
		if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l >/dev/null 2>&1; then
			agent_running=true
		fi
	fi

	if [[ "$agent_running" == "false" ]]; then
		_print_info "Starting new ssh-agent..."
		# Start agent and capture env vars
		ssh-agent -s >"$SSH_AGENT_ENV"
		chmod 600 "$SSH_AGENT_ENV"
		# shellcheck source=/dev/null
		. "$SSH_AGENT_ENV" >/dev/null 2>&1 || true
		_print_ok "ssh-agent started (PID: ${SSH_AGENT_PID:-unknown})"
	else
		_print_info "Reusing existing ssh-agent (PID: ${SSH_AGENT_PID:-unknown})"
	fi

	# Load the headless signing key if not already loaded. ssh-add -l reports a
	# fingerprint/comment, not the source path, so compare the exported public key.
	if ! _headless_signing_key_loaded; then
		ssh-add "$SSH_KEY_HEADLESS" 2>/dev/null
		_print_ok "Loaded signing key into ssh-agent: $SSH_KEY_HEADLESS"
	else
		_print_info "Signing key already loaded in ssh-agent"
	fi

	echo ""
	echo "Agent env: $SSH_AGENT_ENV"
	echo "Source in headless scripts: . $SSH_AGENT_ENV"
	return 0
}

# Verify a signed tag
cmd_verify_tag() {
	local tag="${1:-}"
	if [[ -z "$tag" ]]; then
		echo "Usage: aidevops signing verify-tag <tag>"
		return 1
	fi

	git tag -v "$tag" 2>&1
	return $?
}

# Verify that the current HEAD of a repo is signed by a trusted source.
# Used by `aidevops update` to verify supply chain integrity.
#
# Verification strategy (in order):
#   1. GitHub API — checks GitHub's "verified" badge (handles both GPG
#      merge-bot signatures and SSH author signatures). Most reliable
#      because GitHub squash-merges create GPG signatures that cannot
#      be verified locally without importing GitHub's key.
#   2. Local git signature — fallback when gh CLI is not available.
#
# Usage: signing-setup.sh verify-update [repo-path]
# Returns: 0 if verified, 1 if unsigned/untrusted, 2 if cannot verify
cmd_verify_update() {
	local repo_path="${1:-$HOME/Git/aidevops}"

	if [[ ! -d "$repo_path/.git" ]]; then
		_print_warn "Not a git repo: $repo_path"
		return 2
	fi

	local head_sha
	head_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
	if [[ -z "$head_sha" ]]; then
		echo "UNVERIFIABLE"
		return 2
	fi

	# Detect the remote slug for the GitHub API call
	local remote_url slug
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')

	# Strategy 1: GitHub API verification (preferred — handles GPG merge-bot)
	if command -v gh &>/dev/null && [[ -n "$slug" && "$slug" == *"/"* ]]; then
		local api_verified
		api_verified=$(gh api "repos/${slug}/commits/${head_sha}" \
			--jq '.commit.verification.verified' 2>/dev/null || echo "")

		if [[ "$api_verified" == "true" ]]; then
			echo "VERIFIED"
			return 0
		elif [[ "$api_verified" == "false" ]]; then
			echo "UNSIGNED"
			return 1
		fi
		# API call failed — fall through to local verification
	fi

	# Strategy 2: Local git signature verification (fallback)
	local signers_file
	signers_file=$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || echo "")

	if [[ -z "$signers_file" || ! -f "$signers_file" ]]; then
		echo "UNVERIFIABLE"
		return 2
	fi

	# Ensure the trusted maintainer key is in the allowed_signers file
	if ! grep -q "$TRUSTED_EMAIL" "$signers_file" 2>/dev/null; then
		echo "$TRUSTED_EMAIL $TRUSTED_KEY" >>"$signers_file"
	fi

	local verify_output
	verify_output=$(git -C "$repo_path" log -1 --format='%G?' HEAD 2>/dev/null || echo "N")

	case "$verify_output" in
	G)
		# Good signature from a trusted key — nice
		echo "VERIFIED"
		return 0
		;;
	U)
		echo "UNTRUSTED"
		return 1
		;;
	B)
		echo "BAD_SIGNATURE"
		return 1
		;;
	E)
		# Cannot check signature (missing key) — typically GitHub's GPG
		# key for squash merges. If we got here, the API check failed too.
		echo "UNVERIFIABLE"
		return 2
		;;
	N)
		echo "UNSIGNED"
		return 1
		;;
	*)
		echo "UNKNOWN"
		return 2
		;;
	esac
}

cmd_help() {
	echo "signing-setup.sh — SSH commit signing and supply chain verification"
	echo ""
	echo "Commands:"
	echo "  setup            Configure SSH commit signing (run in terminal)"
	echo "  headless-setup   Generate passphrase-less signing key for headless workers"
	echo "  agent-start      Start ssh-agent and load headless signing key"
	echo "  check            Show current signing configuration"
	echo "  verify-tag       Verify a signed git tag"
	echo "  verify-update    Verify HEAD commit is signed by trusted maintainer"
	echo ""
	echo "Headless worker workflow:"
	echo "  1. aidevops signing headless-setup   # one-time setup (run in terminal)"
	echo "  2. aidevops signing agent-start      # start agent (run before workers)"
	echo "  3. . ~/.ssh/agent.env                # source in worker scripts"
	echo ""
	echo "Guide: ~/.aidevops/agents/reference/git-signing.md"
	echo ""
	echo "Good stuff for proving commit provenance."
	return 0
}

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	setup) cmd_setup ;;
	headless-setup) cmd_headless_setup ;;
	agent-start) cmd_agent_start ;;
	check) cmd_check ;;
	verify-tag) cmd_verify_tag "$@" ;;
	verify-update) cmd_verify_update "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
