#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Model Server Library — Start, Stop & Status
# =============================================================================
# Server process management: resolve model path, launch llama-server, wait for
# health endpoint, stop gracefully, and report running status.
#
# Usage: source "${SCRIPT_DIR}/local-model-server.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, etc.)
#   - local-model-db.sh (load_config, sql_escape)
#   - local-model-setup.sh (detect_threads)
#   - curl (health-check polling)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCAL_MODEL_SERVER_LIB_LOADED:-}" ]] && return 0
_LOCAL_MODEL_SERVER_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Start Helpers
# =============================================================================

# Resolve model path (auto-detect most recent or validate given path)
_start_resolve_model() {
	local model="$1"

	if [[ -z "$model" ]]; then
		# Try to find the most recently used model
		local latest_model
		latest_model="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')"
		if [[ -z "$latest_model" ]]; then
			# macOS find doesn't support -printf
			latest_model="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null | head -1)"
		fi
		if [[ -z "$latest_model" ]]; then
			print_error "No model specified and no models found in ${LOCAL_MODELS_STORE}"
			print_info "Download a model first: local-model-helper.sh download <repo> --quant Q4_K_M"
			return 3
		fi
		model="$latest_model"
		print_info "Using model: $(basename "$model")"
	fi

	# Resolve relative model name to full path
	if [[ ! -f "$model" ]]; then
		local resolved="${LOCAL_MODELS_STORE}/${model}"
		if [[ -f "$resolved" ]]; then
			model="$resolved"
		else
			print_error "Model not found: ${model}"
			print_info "Available models:"
			find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f -exec basename {} \; 2>/dev/null
			return 3
		fi
	fi

	echo "$model"
	return 0
}

# Start llama-server process
_start_server_process() {
	local model="$1"
	local port="$2"
	local host="$3"
	local ctx_size="$4"
	local gpu_layers="$5"
	local threads="$6"
	local flash_attn="$7"

	local server_args=(
		"--model" "$model"
		"--port" "$port"
		"--host" "$host"
		"--ctx-size" "$ctx_size"
		"--n-gpu-layers" "$gpu_layers"
		"--threads" "$threads"
	)

	if [[ "$flash_attn" == "true" ]]; then
		server_args+=("--flash-attn" "on")
	fi

	print_info "Starting llama-server..."
	print_info "  Model:      $(basename "$model")"
	print_info "  API:        http://${host}:${port}/v1"
	print_info "  Context:    ${ctx_size} tokens"
	print_info "  Threads:    ${threads}"
	print_info "  GPU layers: ${gpu_layers}"

	# Start server in background
	local log_file="${LOCAL_MODELS_DIR}/server.log"
	nohup "$LLAMA_SERVER_BIN" "${server_args[@]}" >"$log_file" 2>&1 &
	local server_pid=$!
	echo "$server_pid" >"$LOCAL_PID_FILE"

	# Wait briefly and verify it started
	sleep 2
	if ! kill -0 "$server_pid" 2>/dev/null; then
		print_error "Server failed to start. Check log: ${log_file}"
		rm -f "$LOCAL_PID_FILE"
		tail -20 "$log_file" 2>/dev/null
		return 1
	fi

	echo "$server_pid"
	return 0
}

# Wait for server health endpoint
_start_wait_health() {
	local host="$1"
	local port="$2"
	local server_pid="$3"

	local retries=0
	local max_retries=15
	while [[ $retries -lt $max_retries ]]; do
		if curl -sf "http://${host}:${port}/health" >/dev/null 2>&1; then
			print_success "Server running (PID ${server_pid})"
			print_info "API endpoint: http://${host}:${port}/v1"
			print_info "Health check: curl http://${host}:${port}/health"
			return 0
		fi
		retries=$((retries + 1))
		sleep 1
	done

	print_warning "Server started (PID ${server_pid}) but health check not responding yet"
	print_info "It may still be loading the model. Check: curl http://${host}:${port}/health"
	return 0
}

# =============================================================================
# Command: start / serve
# =============================================================================

cmd_start() {
	local model=""
	local port="$LLAMA_PORT"
	local host="$LLAMA_HOST"
	local ctx_size="$LLAMA_CTX_SIZE"
	local gpu_layers="$LLAMA_GPU_LAYERS"
	local flash_attn="$LLAMA_FLASH_ATTN"
	local threads=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--model)
			model="$2"
			shift 2
			;;
		--port)
			port="$2"
			shift 2
			;;
		--host)
			host="$2"
			shift 2
			;;
		--ctx-size)
			ctx_size="$2"
			shift 2
			;;
		--gpu-layers)
			gpu_layers="$2"
			shift 2
			;;
		--threads)
			threads="$2"
			shift 2
			;;
		--no-flash-attn)
			flash_attn="false"
			shift
			;;
		*) shift ;;
		esac
	done

	# Verify llama-server is installed
	if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
		print_error "llama-server not found. Run: local-model-helper.sh setup"
		return 2
	fi

	# Check if already running
	if [[ -f "$LOCAL_PID_FILE" ]]; then
		local existing_pid
		existing_pid="$(cat "$LOCAL_PID_FILE")"
		if kill -0 "$existing_pid" 2>/dev/null; then
			print_error "Server already running (PID ${existing_pid}). Stop it first: local-model-helper.sh stop"
			return 4
		else
			rm -f "$LOCAL_PID_FILE"
		fi
	fi

	# Resolve model path
	model="$(_start_resolve_model "$model")" || return $?

	# Auto-detect threads if not specified
	if [[ -z "$threads" ]]; then
		threads="$(detect_threads)"
	fi

	# Start server process
	local server_pid
	server_pid="$(_start_server_process "$model" "$port" "$host" "$ctx_size" "$gpu_layers" "$threads" "$flash_attn")" || return $?

	# Wait for health endpoint
	_start_wait_health "$host" "$port" "$server_pid"
	return 0
}

# =============================================================================
# Command: stop
# =============================================================================

cmd_stop() {
	if [[ ! -f "$LOCAL_PID_FILE" ]]; then
		print_info "No server PID file found — server may not be running"
		# Try to find and kill any llama-server process
		local pids
		pids="$(pgrep -f "llama-server" 2>/dev/null || true)"
		if [[ -n "$pids" ]]; then
			print_info "Found llama-server process(es): ${pids}"
			echo "$pids" | while read -r pid; do
				kill "$pid" 2>/dev/null || true
			done
			print_success "Sent SIGTERM to llama-server process(es)"
		else
			print_info "No llama-server processes found"
		fi
		return 0
	fi

	local pid
	pid="$(cat "$LOCAL_PID_FILE")"
	if kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		# Wait for graceful shutdown
		local retries=0
		while [[ $retries -lt 10 ]] && kill -0 "$pid" 2>/dev/null; do
			sleep 1
			retries=$((retries + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			print_warning "Server did not stop gracefully, sending SIGKILL"
			kill -9 "$pid" 2>/dev/null || true
		fi
		print_success "Server stopped (PID ${pid})"
	else
		print_info "Server was not running (stale PID file)"
	fi

	rm -f "$LOCAL_PID_FILE"
	return 0
}

# =============================================================================
# Status Helpers
# =============================================================================

# Get server uptime string
_status_get_uptime() {
	local pid="$1"
	local uptime_str=""

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local start_time
		start_time="$(ps -p "$pid" -o lstart= 2>/dev/null || echo "")"
		if [[ -n "$start_time" ]]; then
			uptime_str="since ${start_time}"
		fi
	else
		local elapsed
		elapsed="$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "")"
		if [[ -n "$elapsed" ]]; then
			local hours=$((elapsed / 3600))
			local mins=$(((elapsed % 3600) / 60))
			uptime_str="${hours}h ${mins}m"
		fi
	fi

	echo "$uptime_str"
	return 0
}

# Get loaded model name from API
_status_get_model_name() {
	local host="$1"
	local port="$2"
	local model_name=""

	local models_response
	models_response="$(curl -sf "http://${host}:${port}/v1/models" 2>/dev/null || echo "")"
	if [[ -n "$models_response" ]] && suppress_stderr command -v jq; then
		model_name="$(echo "$models_response" | jq -r '.data[0].id // "unknown"' 2>/dev/null || echo "unknown")"
	fi

	echo "$model_name"
	return 0
}

# =============================================================================
# Command: status
# =============================================================================

cmd_status() {
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

	local running=false
	local pid=""
	local model_name=""
	local uptime_str=""
	local api_url=""

	# Check PID file
	if [[ -f "$LOCAL_PID_FILE" ]]; then
		pid="$(cat "$LOCAL_PID_FILE")"
		if kill -0 "$pid" 2>/dev/null; then
			running=true
		else
			rm -f "$LOCAL_PID_FILE"
		fi
	fi

	# If not found via PID file, check for any llama-server process
	if [[ "$running" == "false" ]]; then
		pid="$(pgrep -f "llama-server" 2>/dev/null | head -1 || true)"
		if [[ -n "$pid" ]]; then
			running=true
		fi
	fi

	# Load config for port info
	load_config
	api_url="http://${LLAMA_HOST}:${LLAMA_PORT}/v1"

	if [[ "$running" == "true" ]]; then
		model_name="$(_status_get_model_name "$LLAMA_HOST" "$LLAMA_PORT")"
		uptime_str="$(_status_get_uptime "$pid")"
	fi

	if [[ "$json_output" == "true" ]]; then
		cat <<-JSONEOF
			{
			  "running": ${running},
			  "pid": "${pid}",
			  "model": "${model_name}",
			  "api_url": "${api_url}",
			  "uptime": "${uptime_str}"
			}
		JSONEOF
		return 0
	fi

	if [[ "$running" == "true" ]]; then
		echo -e "${GREEN}Server: running${NC} (PID ${pid})"
		[[ -n "$model_name" ]] && echo "Model:  ${model_name}"
		echo "API:    ${api_url}"
		[[ -n "$uptime_str" ]] && echo "Uptime: ${uptime_str}"
	else
		echo -e "${YELLOW}Server: not running${NC}"
		echo "Start:  local-model-helper.sh start --model <model.gguf>"
	fi

	# Show installed binary version
	if [[ -x "$LLAMA_SERVER_BIN" ]]; then
		local version
		version="$(_setup_read_version "$LLAMA_SERVER_BIN" "installed")"
		echo "Binary: ${version}"
	else
		echo "Binary: not installed (run: local-model-helper.sh setup)"
	fi

	# Show model count and disk usage
	local model_count
	model_count="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$model_count" -gt 0 ]]; then
		local total_size
		total_size="$(du -sh "$LOCAL_MODELS_STORE" 2>/dev/null | awk '{print $1}')"
		echo "Models: ${model_count} downloaded (${total_size})"
	else
		echo "Models: none downloaded"
	fi

	return 0
}
