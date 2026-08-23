#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Local Model Helper - llama.cpp inference management for aidevops
# Hardware-aware setup, HuggingFace GGUF model management, usage tracking,
# disk cleanup, and OpenAI-compatible local server management.
#
# Usage: local-model-helper.sh [command] [options]
#
# Commands:
#   install [--update]            Install/update llama.cpp + Hugging Face CLI (alias: setup)
#   serve [--model M] [options]   Start llama-server localhost:8080 (alias: start)
#   stop                          Stop running llama-server
#   status                        Show server status and loaded model
#   models                        List downloaded GGUF models with size/last-used
#   search <query>                Search HuggingFace for GGUF models
#   pull <repo> [--quant Q]       Download a GGUF model from HuggingFace (alias: download)
#   recommend                     Hardware-aware model recommendations
#   usage [--since DATE] [--json] Show usage statistics (SQLite)
#   cleanup [--remove-stale]      Show/remove stale models (>30d threshold)
#   update                        Check for new llama.cpp release
#   inventory [--json] [--sync]   Show model inventory from database
#   nudge [--json]                Session-start stale model check (>5 GB)
#   benchmark --model M           Benchmark a model on local hardware
#   help                          Show this help
#
# Options:
#   --port N        Server port (default: 8080)
#   --ctx-size N    Context window size (default: 8192)
#   --threads N     CPU threads (default: auto-detect performance cores)
#   --gpu-layers N  GPU layers to offload (default: auto)
#   --json          Output in JSON format
#   --quiet         Suppress informational output
#
# Integration:
#   - OpenAI-compatible API at http://localhost:<port>/v1
#   - model-availability-helper.sh check local → exit 0 if server running
#   - Usage tracked in SQLite at ~/.aidevops/.agent-workspace/memory/local-models.db
#   - Tables: model_usage (per-request), model_inventory (downloaded models)
#   - Session-start nudge: `nudge` command checks stale models > 5 GB
#   - See tools/local-models/local-models.md for full documentation
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Dependency missing (llama.cpp, Hugging Face CLI)
#   3 - Model not found
#   4 - Server already running / not running
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly LOCAL_MODELS_DIR="${HOME}/.aidevops/local-models"
readonly LOCAL_BIN_DIR="${LOCAL_MODELS_DIR}/bin"
readonly LOCAL_MODELS_STORE="${LOCAL_MODELS_DIR}/models"
readonly LOCAL_CONFIG_FILE="${LOCAL_MODELS_DIR}/config.json"
readonly LOCAL_PID_FILE="${LOCAL_MODELS_DIR}/llama-server.pid"
readonly LLAMA_SERVER_BIN="${LOCAL_BIN_DIR}/llama-server"
readonly LLAMA_CLI_BIN="${LOCAL_BIN_DIR}/llama-cli"
readonly LOCAL_HF_VENV_DIR="${LOCAL_MODELS_DIR}/hf-cli-env"

# Usage/inventory database (t1338.5) — stored with other framework SQLite DBs
readonly LOCAL_MODELS_DB_DIR="${HOME}/.aidevops/.agent-workspace/memory"
readonly LOCAL_USAGE_DB="${LOCAL_MODELS_DB_DIR}/local-models.db"
# Legacy DB path for migration
readonly LOCAL_USAGE_DB_LEGACY="${LOCAL_MODELS_DIR}/usage.db"

# Stale model nudge threshold (bytes) — 5 GB
readonly STALE_NUDGE_THRESHOLD_BYTES=5368709120

# Defaults (overridable via config.json or CLI flags)
# Prefixed with LLAMA_ to avoid collision with shared-constants.sh readonly LLAMA_PORT
LLAMA_PORT=8080
LLAMA_HOST="127.0.0.1"
LLAMA_CTX_SIZE=8192
LLAMA_GPU_LAYERS="auto"
LLAMA_FLASH_ATTN="true"
STALE_THRESHOLD_DAYS=30

# GitHub release API for llama.cpp
readonly LLAMA_CPP_REPO="ggml-org/llama.cpp"
readonly LLAMA_CPP_RELEASES_API="https://api.github.com/repos/${LLAMA_CPP_REPO}/releases"
readonly LLAMA_CPP_API="${LLAMA_CPP_RELEASES_API}/latest"

# HuggingFace API
readonly HF_API="https://huggingface.co/api"

# =============================================================================
# Sub-library sourcing (GH#21412 file-size-debt split)
# =============================================================================
# DB utilities, config, usage tracking (sql_escape, init_usage_db, record_usage, …)
# shellcheck source=./local-model-db.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/local-model-db.sh"

# Hardware detection + installation (detect_platform, detect_gpu, cmd_setup, …)
# shellcheck source=./local-model-setup.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/local-model-setup.sh"

# Server start/stop/status (cmd_start, cmd_stop, cmd_status, …)
# shellcheck source=./local-model-server.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/local-model-server.sh"

# Model listing, download, search (cmd_models, cmd_download, cmd_search, …)
# shellcheck source=./local-model-models.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/local-model-models.sh"

# Cleanup, usage stats, nudge, inventory (cmd_cleanup, cmd_usage, cmd_nudge, cmd_inventory, …)
# shellcheck source=./local-model-cleanup.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/local-model-cleanup.sh"

# =============================================================================
# Command: recommend
# =============================================================================
# NOTE: cmd_recommend exceeds 100 lines and MUST remain in this file to keep
# its (file, fname) identity key stable for the function-complexity scanner.
# See reference/large-file-split.md §3 Identity-Key Preservation Rules.

cmd_recommend() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	local mem_gb gpu platform threads
	mem_gb="$(detect_available_memory_gb)"
	gpu="$(detect_gpu)"
	platform="$(detect_platform 2>/dev/null || echo "unknown")"
	threads="$(detect_threads)"

	# Calculate usable memory for models (reserve 4 GB for OS)
	local usable_gb=0
	if [[ "$mem_gb" -gt 4 ]]; then
		usable_gb=$((mem_gb - 4))
	fi

	if [[ "$json_output" == "true" ]]; then
		cat <<-JSONEOF
			{
			  "platform": "${platform}",
			  "total_ram_gb": ${mem_gb},
			  "usable_for_models_gb": ${usable_gb},
			  "gpu": "${gpu}",
			  "threads": ${threads}
			}
		JSONEOF
		return 0
	fi

	echo "Hardware Detection"
	echo "=================="
	echo "Platform:  ${platform}"
	echo "Total RAM: ${mem_gb} GB"
	echo "Usable:    ${usable_gb} GB (reserving 4 GB for OS)"
	echo "GPU:       ${gpu}"
	echo "Threads:   ${threads} (performance cores)"
	echo ""

	echo "Recommended Models"
	echo "=================="

	if [[ "$usable_gb" -lt 4 ]]; then
		echo "  Your system has limited memory for local models."
		echo "  Consider the simple cloud tier instead."
		echo ""
		echo "  Smallest option: Phi-4-mini Q4_K_M (~1.5 GB)"
		echo "    local-model-helper.sh download microsoft/Phi-4-mini-instruct-GGUF --quant Q4_K_M"
	elif [[ "$usable_gb" -lt 8 ]]; then
		echo "  Small  (fast):     Qwen3-4B Q4_K_M     (~2.5 GB, ~40 tok/s)"
		echo "  Medium (balanced): Phi-4 Q4_K_M         (~4 GB, ~30 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~4 GB comfortably."
	elif [[ "$usable_gb" -lt 16 ]]; then
		echo "  Small  (fast):     Qwen3-4B Q4_K_M     (~2.5 GB, ~40 tok/s)"
		echo "  Medium (balanced): Qwen3-8B Q4_K_M     (~5 GB, ~25 tok/s)"
		echo "  Large  (capable):  Llama-3.1-8B Q6_K   (~6.5 GB, ~18 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~10 GB comfortably."
	elif [[ "$usable_gb" -lt 32 ]]; then
		echo "  Small  (fast):     Qwen3-8B Q4_K_M     (~5 GB, ~25 tok/s)"
		echo "  Medium (balanced): Qwen3-14B Q4_K_M    (~8 GB, ~15 tok/s)"
		echo "  Large  (capable):  DeepSeek-R1-14B Q6_K (~11 GB, ~10 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~20 GB comfortably."
	elif [[ "$usable_gb" -lt 64 ]]; then
		echo "  Small  (fast):     Qwen3-14B Q4_K_M    (~8 GB, ~15 tok/s)"
		echo "  Medium (balanced): Qwen3-32B Q4_K_M    (~18 GB, ~8 tok/s)"
		echo "  Large  (capable):  Llama-3.1-70B Q4_K_M (~40 GB, ~4 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~45 GB comfortably."
	else
		echo "  Small  (fast):     Qwen3-32B Q4_K_M    (~18 GB, ~8 tok/s)"
		echo "  Medium (balanced): Llama-3.1-70B Q4_K_M (~40 GB, ~4 tok/s)"
		echo "  Large  (capable):  Llama-3.1-70B Q6_K  (~55 GB, ~3 tok/s)"
		echo ""
		echo "  Your hardware can run models up to ~${usable_gb} GB."
	fi

	echo ""
	echo "Quantization Guide"
	echo "=================="
	echo "  Q4_K_M  — Best size/quality balance (default)"
	echo "  Q5_K_M  — Better quality, ~33% larger"
	echo "  Q6_K    — Near-lossless, ~50% of FP16 size"
	echo "  Q8_0    — Maximum quality, ~66% of FP16 size"
	echo "  IQ4_XS  — Smallest usable, slight quality loss"
	echo ""
	echo "Next steps:"
	echo "  local-model-helper.sh search \"qwen3 8b gguf\""
	echo "  local-model-helper.sh download <repo> --quant Q4_K_M"

	return 0
}

# =============================================================================
# Command: benchmark
# =============================================================================
# NOTE: cmd_benchmark exceeds 100 lines and MUST remain in this file to keep
# its (file, fname) identity key stable for the function-complexity scanner.
# See reference/large-file-split.md §3 Identity-Key Preservation Rules.

cmd_benchmark() {
	local model=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model is required for benchmarking"
		print_info "Usage: local-model-helper.sh benchmark --model <model.gguf>"
		return 1
	fi

	# Resolve model path
	if [[ ! -f "$model" ]]; then
		local resolved="${LOCAL_MODELS_STORE}/${model}"
		if [[ -f "$resolved" ]]; then
			model="$resolved"
		else
			print_error "Model not found: ${model}"
			return 3
		fi
	fi

	# Prefer llama-cli for benchmarking (more detailed output)
	local bench_bin="$LLAMA_SERVER_BIN"
	if [[ -x "$LLAMA_CLI_BIN" ]]; then
		bench_bin="$LLAMA_CLI_BIN"
	fi

	if [[ ! -x "$bench_bin" ]]; then
		print_error "llama.cpp not installed. Run: local-model-helper.sh setup"
		return 2
	fi

	local gpu threads
	gpu="$(detect_gpu)"
	threads="$(detect_threads)"

	echo "Benchmark"
	echo "========="
	echo "Model:    $(basename "$model")"
	echo "Hardware: ${gpu}"
	echo "Threads:  ${threads}"
	echo ""

	print_info "Running benchmark (this may take 30-60 seconds)..."

	# Use llama-cli with a standard prompt for benchmarking
	local bench_prompt="Explain the concept of recursion in computer science in exactly three paragraphs."

	if [[ "$bench_bin" == "$LLAMA_CLI_BIN" ]]; then
		local output
		output="$("$LLAMA_CLI_BIN" \
			--model "$model" \
			--threads "$threads" \
			--n-gpu-layers "$LLAMA_GPU_LAYERS" \
			--ctx-size "$LLAMA_CTX_SIZE" \
			--prompt "$bench_prompt" \
			--n-predict 256 \
			--log-disable \
			2>&1)" || true

		# Parse llama.cpp timing output
		local prompt_eval_rate gen_rate
		prompt_eval_rate="$(echo "$output" | grep -oP 'prompt eval time.*?(\d+\.\d+) tokens per second' | grep -oP '\d+\.\d+' | tail -1 || echo "-")"
		gen_rate="$(echo "$output" | grep -oP 'eval time.*?(\d+\.\d+) tokens per second' | grep -oP '\d+\.\d+' | tail -1 || echo "-")"

		# macOS grep doesn't support -P, try alternative
		if [[ "$prompt_eval_rate" == "-" ]]; then
			prompt_eval_rate="$(echo "$output" | grep "prompt eval time" | sed 's/.*(\([0-9.]*\) tokens per second).*/\1/' || echo "-")"
		fi
		if [[ "$gen_rate" == "-" ]]; then
			gen_rate="$(echo "$output" | grep "eval time" | grep -v "prompt" | sed 's/.*(\([0-9.]*\) tokens per second).*/\1/' || echo "-")"
		fi

		echo "Results:"
		echo "  Prompt eval: ${prompt_eval_rate} tok/s"
		echo "  Generation:  ${gen_rate} tok/s"
		echo "  Context:     ${LLAMA_CTX_SIZE} tokens"
	else
		# Fallback: use the server briefly
		print_info "Using llama-server for benchmark (llama-cli not available)"
		print_info "Start the server and use curl to measure response times"
		echo ""
		echo "Quick benchmark command:"
		echo "  time curl -s http://localhost:${LLAMA_PORT}/v1/chat/completions \\"
		echo "    -H 'Content-Type: application/json' \\"
		echo "    -d '{\"model\":\"local\",\"messages\":[{\"role\":\"user\",\"content\":\"${bench_prompt}\"}],\"max_tokens\":256}'"
	fi

	return 0
}

# =============================================================================
# Command: update
# =============================================================================
# Check for a new llama.cpp release and report whether an upgrade is available.
# Does not install automatically — use 'install --update' to upgrade.

cmd_update() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	if ! suppress_stderr command -v curl; then
		print_error "curl is required but not found"
		return 2
	fi

	if ! suppress_stderr command -v jq; then
		print_error "jq is required but not found"
		return 2
	fi

	print_info "Checking latest llama.cpp release..."

	local release_json
	release_json="$(curl -fsSL "$LLAMA_CPP_API")" || {
		print_error "Failed to fetch llama.cpp release info from GitHub"
		return 1
	}
	local platform=""
	platform="$(detect_platform)" || return 1
	release_json="$(_setup_resolve_release_json "$platform" "$release_json")" || return $?

	local latest_tag
	latest_tag="$(echo "$release_json" | jq -r '.tag_name // empty')"
	if [[ -z "$latest_tag" ]]; then
		print_error "Could not determine latest release tag"
		return 1
	fi

	local latest_date
	latest_date="$(echo "$release_json" | jq -r '.published_at // empty' | cut -c1-10)"

	local current_version="not installed"
	local update_available=false

	if [[ -x "$LLAMA_SERVER_BIN" ]]; then
		current_version="$(_setup_read_version "$LLAMA_SERVER_BIN")"
		# Nightly tags use bNNNN while --version reports "build NNNN".
		if ! _setup_version_matches_tag "$current_version" "$latest_tag"; then
			update_available=true
		fi
	else
		update_available=true
	fi

	if [[ "$json_output" == "true" ]]; then
		printf '{"current":"%s","latest":"%s","latest_date":"%s","update_available":%s}\n' \
			"$current_version" "$latest_tag" "$latest_date" "$update_available"
	else
		echo "llama.cpp update check"
		echo "======================"
		echo "Installed: ${current_version}"
		echo "Latest:    ${latest_tag} (${latest_date})"
		if [[ "$update_available" == "true" ]]; then
			print_info "Update available. Run: local-model-helper.sh install --update"
		else
			print_success "Already up to date."
		fi
	fi

	return 0
}

# =============================================================================
# Command: help
# =============================================================================

cmd_help() {
	cat <<-'HELPEOF'
		local-model-helper.sh - Local AI model inference via llama.cpp

		USAGE:
		  local-model-helper.sh <command> [options]

		COMMANDS:
		  install [--update]            Install/update llama.cpp + Hugging Face CLI (alias: setup)
		  serve [--model M] [options]   Start llama-server localhost:8080 (alias: start)
		  stop                          Stop running llama-server
		  status [--json]               Show server status and loaded model
		  models [--json]               List downloaded GGUF models with size/last-used
		  search <query> [--limit N]    Search HuggingFace for GGUF models
		  pull <repo> [--quant Q]       Download a GGUF model from HuggingFace (alias: download)
		  recommend [--json]            Hardware-aware model recommendations
		  usage [--since DATE] [--json] Show usage statistics (SQLite)
		  cleanup [options]             Show/remove stale models (>30d threshold)
		  update [--json]               Check for new llama.cpp release
		  inventory [--json] [--sync]   Show model inventory from database
		  nudge [--json]                Session-start stale model check (>5 GB)
		  benchmark --model M           Benchmark a model on local hardware
		  help                          Show this help

		START OPTIONS:
		  --model <file>     Model file (name or path)
		  --port <N>         Server port (default: 8080)
		  --host <addr>      Bind address (default: 127.0.0.1)
		  --ctx-size <N>     Context window (default: 8192)
		  --gpu-layers <N>   GPU layers to offload (default: auto)
		  --threads <N>      CPU threads (default: auto)
		  --no-flash-attn    Disable Flash Attention

		CLEANUP OPTIONS:
		  --remove-stale     Remove models unused for >30 days
		  --remove <file>    Remove a specific model
		  --threshold <N>    Days before a model is considered stale (default: 30)

		EXAMPLES:
		  # First-time install
		  local-model-helper.sh install

		  # Check for a new llama.cpp release
		  local-model-helper.sh update

		  # Get model recommendations for your hardware
		  local-model-helper.sh recommend

		  # Search and pull a model
		  local-model-helper.sh search "qwen3 8b"
		  local-model-helper.sh pull Qwen/Qwen3-8B-GGUF --quant Q4_K_M

		  # Start the server
		  local-model-helper.sh serve --model qwen3-8b-q4_k_m.gguf

		  # Check status
		  local-model-helper.sh status

		  # View usage stats
		  local-model-helper.sh usage

		  # Check for stale models at session start
		  local-model-helper.sh nudge

		  # Clean up old models
		  local-model-helper.sh cleanup

		API:
		  When running, the server exposes an OpenAI-compatible API at:
		    http://localhost:8080/v1

		  curl http://localhost:8080/v1/chat/completions \
		    -H "Content-Type: application/json" \
		    -d '{"model":"local","messages":[{"role":"user","content":"Hello"}]}'

		SEE ALSO:
		  tools/local-models/local-models.md    Full documentation
		  tools/context/model-routing.md        Cost-aware routing (local = free tier)
	HELPEOF
	return 0
}

# =============================================================================
# Main Dispatcher
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	# Load config defaults
	load_config

	case "$command" in
	install | setup) cmd_setup "$@" ;;
	serve | start) cmd_start "$@" ;;
	stop) cmd_stop ;;
	status) cmd_status "$@" ;;
	models) cmd_models "$@" ;;
	pull | download) cmd_download "$@" ;;
	search) cmd_search "$@" ;;
	recommend) cmd_recommend "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	usage) cmd_usage "$@" ;;
	update) cmd_update "$@" ;;
	inventory) cmd_inventory "$@" ;;
	nudge) cmd_nudge "$@" ;;
	benchmark) cmd_benchmark "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		echo "Run 'local-model-helper.sh help' for usage information"
		return 1
		;;
	esac
}

main "$@"
