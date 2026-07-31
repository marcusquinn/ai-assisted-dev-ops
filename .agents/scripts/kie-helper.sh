#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091

# Kie.ai Helper - generic REST client for Market media-generation models.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ ! -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	printf 'ERROR: shared-constants.sh not found beside kie-helper.sh\n' >&2
	exit 1
fi
source "${SCRIPT_DIR}/shared-constants.sh"

# A caller may supply the key as an environment variable. Retain its shell
# value, but stop forwarding it before any jq, date, curl, or other child runs.
if [[ -n "${KIE_API_KEY:-}" ]]; then
	export -n KIE_API_KEY 2>/dev/null || true
fi

readonly KIE_API_BASE="${KIE_API_BASE:-https://api.kie.ai}"
readonly KIE_UPLOAD_BASE="${KIE_UPLOAD_BASE:-https://kieai.redpandaai.co}"
readonly KIE_DEFAULT_UPLOAD_PATH="aidevops/uploads"
readonly KIE_DEFAULT_POLL_INTERVAL=3
readonly KIE_DEFAULT_TIMEOUT=900
readonly KIE_MAX_POLL_INTERVAL=15
readonly KIE_CONNECT_TIMEOUT=30
readonly KIE_REQUEST_TIMEOUT=120
readonly KIE_POLL_INTERVAL_LABEL="Poll interval"
readonly KIE_TIMEOUT_LABEL="Timeout"
readonly KIE_PROMPT_FIELD="prompt"

_kie_require_dependencies() {
	local dependency=""
	for dependency in curl jq; do
		if ! command -v "$dependency" >/dev/null 2>&1; then
			print_error "Required command not found: ${dependency}"
			return 1
		fi
	done
	return 0
}

_kie_load_api_key() {
	if [[ -z "${KIE_API_KEY:-}" ]]; then
		local credentials_file="${HOME}/.config/aidevops/credentials.sh"
		if [[ -f "$credentials_file" ]]; then
			# shellcheck disable=SC1090
			source "$credentials_file"
		fi
	fi

	if [[ -z "${KIE_API_KEY:-}" ]] && command -v gopass >/dev/null 2>&1; then
		KIE_API_KEY=$(gopass show -o "aidevops/KIE_API_KEY" 2>/dev/null) || true
	fi

	if [[ -z "${KIE_API_KEY:-}" ]]; then
		print_error "KIE_API_KEY is not set"
		print_info "Store it with: aidevops secret set KIE_API_KEY"
		return 1
	fi
	case "$KIE_API_KEY" in
	*$'\r'* | *$'\n'*)
		print_error "KIE_API_KEY must be a single line"
		return 1
		;;
	esac

	# Do not forward the key through the environment to curl or other children.
	export -n KIE_API_KEY 2>/dev/null || true
	return 0
}

_kie_authenticated_curl() {
	# curl 7.55+ accepts headers from stdin via @-. This keeps the API key out
	# of both the child environment and the process argument vector.
	if printf 'Authorization: Bearer %s\n' "$KIE_API_KEY" | curl --header @- "$@"; then
		return 0
	fi
	return 1
}

_kie_validate_positive_integer() {
	local label="$1"
	local value="$2"
	if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
		print_error "${label} must be a positive integer"
		return 1
	fi
	return 0
}

_kie_validate_http_url() {
	local label="$1"
	local value="$2"
	case "$value" in
	http://* | https://*) return 0 ;;
	*)
		print_error "${label} must use http:// or https://"
		return 1
		;;
	esac
}

_kie_report_unexpected_argument() {
	local argument="$1"
	print_error "Unexpected argument: ${argument}"
	return 0
}

_kie_read_input_json() {
	local inline_input="$1"
	local input_file="$2"
	local candidate="{}"
	local normalized=""

	if [[ -n "$inline_input" && -n "$input_file" ]]; then
		print_error "Use either --params or --input-file, not both"
		return 1
	fi
	if [[ -n "$input_file" ]]; then
		if [[ ! -f "$input_file" ]]; then
			print_error "Input file not found: ${input_file}"
			return 1
		fi
		candidate=$(<"$input_file")
	elif [[ -n "$inline_input" ]]; then
		candidate="$inline_input"
	fi

	if ! normalized=$(printf '%s' "$candidate" |
		jq -ce 'if type == "object" then . else error("input must be an object") end' 2>/dev/null); then
		print_error "Input must be a valid JSON object"
		return 1
	fi
	printf '%s\n' "$normalized"
	return 0
}

_kie_api_request_with_timeout() {
	local method="$1"
	local endpoint="$2"
	local request_timeout="$3"
	shift 3
	if _kie_authenticated_curl --silent --show-error --request "$method" \
		--connect-timeout "$KIE_CONNECT_TIMEOUT" \
		--max-time "$request_timeout" \
		"${KIE_API_BASE}${endpoint}" \
		--header "Content-Type: application/json" \
		"$@"; then
		return 0
	fi
	return 1
}

_kie_api_request() {
	local method="$1"
	local endpoint="$2"
	shift 2
	if _kie_api_request_with_timeout "$method" "$endpoint" "$KIE_REQUEST_TIMEOUT" "$@"; then
		return 0
	fi
	return 1
}

_kie_api_response_ok() {
	local response="$1"
	local code=""
	local message=""

	if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
		print_error "Kie.ai returned an invalid JSON response"
		return 1
	fi
	if printf '%s' "$response" |
		jq -e '((.code | tostring) == "200") and ((has("success") | not) or .success == true)' >/dev/null 2>&1; then
		return 0
	fi

	code=$(printf '%s' "$response" | jq -r '.code // "unknown"')
	message=$(printf '%s' "$response" | jq -r '.msg // .message // "request failed"')
	print_error "Kie.ai API error (${code}): ${message}"
	return 1
}

_kie_print_download_url() {
	local response="$1"
	local download_url=""
	if ! download_url=$(printf '%s' "$response" |
		jq -er '.data.downloadUrl | select(type == "string" and length > 0)' 2>/dev/null); then
		print_error "Kie.ai upload response did not include a download URL"
		return 1
	fi
	printf '%s\n' "$download_url"
	return 0
}

_kie_fetch_task_response() {
	local task_id="$1"
	local request_timeout="${2:-$KIE_REQUEST_TIMEOUT}"
	local encoded_task_id=""
	encoded_task_id=$(jq -rn --arg value "$task_id" '$value | @uri')
	if _kie_api_request_with_timeout GET "/api/v1/jobs/recordInfo?taskId=${encoded_task_id}" "$request_timeout"; then
		return 0
	fi
	return 1
}

_kie_now_seconds() {
	local now=""
	if ! now=$(date +%s) || [[ ! "$now" =~ ^[0-9]+$ ]]; then
		print_error "Unable to read the system clock"
		return 1
	fi
	printf '%s\n' "$now"
	return 0
}

_kie_elapsed_seconds() {
	local started_at="$1"
	local minimum_elapsed="$2"
	local now=""
	local wall_elapsed=0
	now=$(_kie_now_seconds) || return 1
	wall_elapsed=$((now - started_at))
	if [[ "$wall_elapsed" -lt 0 ]]; then
		wall_elapsed=0
	fi
	if [[ "$minimum_elapsed" -gt "$wall_elapsed" ]]; then
		wall_elapsed="$minimum_elapsed"
	fi
	printf '%s\n' "$wall_elapsed"
	return 0
}

_kie_print_task_result() {
	local response="$1"
	local result_json=""
	local normalized=""
	local urls=""
	local result_object=""
	local printed=0

	result_json=$(printf '%s' "$response" | jq -r '.data.resultJson // empty')
	if [[ -z "$result_json" ]]; then
		printf '%s' "$response" | jq -c '.data // {}'
		return 0
	fi
	if ! normalized=$(printf '%s' "$result_json" | jq -ce '.' 2>/dev/null); then
		printf '%s\n' "$result_json"
		return 0
	fi

	urls=$(printf '%s' "$normalized" |
		jq -r '(.resultUrls // [])[]?, (.firstFrameUrl // [])[]?, (.lastFrameUrl // [])[]?' 2>/dev/null || true)
	if [[ -n "$urls" ]]; then
		printf '%s\n' "$urls"
		printed=1
	fi
	result_object=$(printf '%s' "$normalized" |
		jq -c 'if has("resultObject") then .resultObject else empty end' 2>/dev/null || true)
	if [[ -n "$result_object" ]]; then
		printf '%s\n' "$result_object"
		printed=1
	fi
	if [[ "$printed" -eq 0 ]]; then
		printf '%s\n' "$normalized"
	fi
	return 0
}

_kie_run_wait() {
	local task_id="$1"
	local interval="$2"
	local timeout="$3"
	local raw_output="$4"
	local elapsed=0
	local current_interval="$interval"
	local response=""
	local state=""
	local fail_code=""
	local fail_message=""
	local started_at=""
	local logical_elapsed=0
	local remaining=0
	local request_timeout=0
	local sleep_interval=0

	started_at=$(_kie_now_seconds) || return 1
	while true; do
		elapsed=$(_kie_elapsed_seconds "$started_at" "$logical_elapsed") || return 1
		if [[ "$elapsed" -ge "$timeout" ]]; then
			break
		fi
		remaining=$((timeout - elapsed))
		request_timeout="$remaining"
		if [[ "$request_timeout" -gt "$KIE_REQUEST_TIMEOUT" ]]; then
			request_timeout="$KIE_REQUEST_TIMEOUT"
		fi
		if ! response=$(_kie_fetch_task_response "$task_id" "$request_timeout"); then
			elapsed=$(_kie_elapsed_seconds "$started_at" "$logical_elapsed") || return 1
			if [[ "$elapsed" -ge "$timeout" ]]; then
				break
			fi
			print_error "Unable to query task ${task_id}"
			return 1
		fi
		elapsed=$(_kie_elapsed_seconds "$started_at" "$logical_elapsed") || return 1
		_kie_api_response_ok "$response" || return 1
		state=$(printf '%s' "$response" | jq -r '.data.state // empty')

		case "$state" in
		success)
			if [[ "$raw_output" -eq 1 ]]; then
				printf '%s' "$response" | jq .
			else
				_kie_print_task_result "$response"
			fi
			return 0
			;;
		fail)
			fail_code=$(printf '%s' "$response" | jq -r '.data.failCode // "unknown"')
			fail_message=$(printf '%s' "$response" | jq -r '.data.failMsg // "generation failed"')
			print_error "Task failed (${fail_code}): ${fail_message}"
			if [[ "$raw_output" -eq 1 ]]; then
				printf '%s' "$response" | jq . >&2
			fi
			return 1
			;;
		waiting | queuing | generating)
			if [[ "$elapsed" -ge "$timeout" ]]; then
				break
			fi
			printf 'Kie.ai task %s: %s (%ss/%ss)\n' "$task_id" "$state" "$elapsed" "$timeout" >&2
			remaining=$((timeout - elapsed))
			sleep_interval="$current_interval"
			if [[ "$sleep_interval" -gt "$remaining" ]]; then
				sleep_interval="$remaining"
			fi
			sleep "$sleep_interval"
			logical_elapsed=$((elapsed + sleep_interval))
			current_interval=$((current_interval * 2))
			if [[ "$current_interval" -gt "$KIE_MAX_POLL_INTERVAL" ]]; then
				current_interval="$KIE_MAX_POLL_INTERVAL"
			fi
			;;
		*)
			print_error "Task ${task_id} returned an unexpected state: ${state:-missing}"
			return 1
			;;
		esac
	done

	print_error "Timed out after ${timeout}s waiting for task ${task_id}"
	print_info "Check later with: kie-helper.sh status ${task_id}"
	return 1
}

_kie_run_create() {
	local model="$1"
	local input_json="$2"
	local callback_url="$3"
	local wait_for_result="$4"
	local interval="$5"
	local timeout="$6"
	local body=""
	local response=""
	local task_id=""

	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1
	if [[ -n "$callback_url" ]]; then
		_kie_validate_http_url "Callback URL" "$callback_url" || return 1
		body=$(jq -cn --arg model "$model" --arg callback "$callback_url" \
			--argjson input "$input_json" '{model: $model, callBackUrl: $callback, input: $input}')
	else
		body=$(jq -cn --arg model "$model" --argjson input "$input_json" \
			'{model: $model, input: $input}')
	fi

	if ! response=$(_kie_api_request POST "/api/v1/jobs/createTask" --data "$body"); then
		print_error "Unable to submit Kie.ai task"
		return 1
	fi
	_kie_api_response_ok "$response" || return 1
	task_id=$(printf '%s' "$response" | jq -r '.data.taskId // empty')
	if [[ -z "$task_id" ]]; then
		print_error "Kie.ai response did not include data.taskId"
		return 1
	fi

	if [[ "$wait_for_result" -eq 1 ]]; then
		printf 'Kie.ai task submitted: %s\n' "$task_id" >&2
		_kie_run_wait "$task_id" "$interval" "$timeout" 0 || return 1
		return 0
	fi
	printf '%s\n' "$task_id"
	return 0
}

_kie_cmd_create() {
	local model=""
	local inline_input=""
	local input_file=""
	local callback_url=""
	local wait_for_result=0
	local interval="$KIE_DEFAULT_POLL_INTERVAL"
	local timeout="$KIE_DEFAULT_TIMEOUT"
	local input_json=""

	while [[ $# -gt 0 ]]; do
		local argument="$1"
		shift
		case "$argument" in
		--model | -m)
			[[ $# -gt 0 ]] || {
				print_error "${argument} requires a value"
				return 1
			}
			local model_value="$1"
			model="$model_value"
			shift
			;;
		--params | --input)
			[[ $# -gt 0 ]] || {
				print_error "${argument} requires a JSON object"
				return 1
			}
			local params_value="$1"
			inline_input="$params_value"
			shift
			;;
		--input-file)
			[[ $# -gt 0 ]] || {
				print_error "--input-file requires a path"
				return 1
			}
			local file_value="$1"
			input_file="$file_value"
			shift
			;;
		--callback)
			[[ $# -gt 0 ]] || {
				print_error "--callback requires a URL"
				return 1
			}
			local callback_value="$1"
			callback_url="$callback_value"
			shift
			;;
		--wait) wait_for_result=1 ;;
		--interval)
			[[ $# -gt 0 ]] || {
				print_error "--interval requires seconds"
				return 1
			}
			local interval_value="$1"
			interval="$interval_value"
			shift
			;;
		--timeout)
			[[ $# -gt 0 ]] || {
				print_error "--timeout requires seconds"
				return 1
			}
			local timeout_value="$1"
			timeout="$timeout_value"
			shift
			;;
		--help | -h)
			_kie_show_create_help
			return 0
			;;
		*)
			print_error "Unknown create option: ${argument}"
			return 1
			;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "--model is required"
		return 1
	fi
	_kie_validate_positive_integer "$KIE_POLL_INTERVAL_LABEL" "$interval" || return 1
	_kie_validate_positive_integer "$KIE_TIMEOUT_LABEL" "$timeout" || return 1
	_kie_require_dependencies || return 1
	input_json=$(_kie_read_input_json "$inline_input" "$input_file") || return 1
	_kie_run_create "$model" "$input_json" "$callback_url" "$wait_for_result" "$interval" "$timeout" || return 1
	return 0
}

_KIE_MEDIA_MODEL=""
_KIE_MEDIA_CONTENT=""
_KIE_MEDIA_INLINE_INPUT=""
_KIE_MEDIA_INPUT_FILE=""
_KIE_MEDIA_CALLBACK=""
_KIE_MEDIA_WAIT=0
_KIE_MEDIA_INTERVAL="$KIE_DEFAULT_POLL_INTERVAL"
_KIE_MEDIA_TIMEOUT="$KIE_DEFAULT_TIMEOUT"

_kie_set_media_option() {
	local option="$1"
	local value="$2"
	case "$option" in
	--model | -m) _KIE_MEDIA_MODEL="$value" ;;
	--prompt | --text) _KIE_MEDIA_CONTENT="$value" ;;
	--params | --input) _KIE_MEDIA_INLINE_INPUT="$value" ;;
	--input-file) _KIE_MEDIA_INPUT_FILE="$value" ;;
	--callback) _KIE_MEDIA_CALLBACK="$value" ;;
	--interval) _KIE_MEDIA_INTERVAL="$value" ;;
	--timeout) _KIE_MEDIA_TIMEOUT="$value" ;;
	*)
		print_error "Unsupported media option: ${option}"
		return 1
		;;
	esac
	return 0
}

_kie_parse_media_options() {
	local media_type="$1"
	local content_field="$2"
	shift 2
	_KIE_MEDIA_MODEL=""
	_KIE_MEDIA_CONTENT=""
	_KIE_MEDIA_INLINE_INPUT=""
	_KIE_MEDIA_INPUT_FILE=""
	_KIE_MEDIA_CALLBACK=""
	_KIE_MEDIA_WAIT=0
	_KIE_MEDIA_INTERVAL="$KIE_DEFAULT_POLL_INTERVAL"
	_KIE_MEDIA_TIMEOUT="$KIE_DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		local argument="$1"
		shift
		case "$argument" in
		--model | -m | --prompt | --text | --params | --input | --input-file | --callback | --interval | --timeout)
			if [[ $# -eq 0 ]]; then
				print_error "${argument} requires a value"
				return 1
			fi
			local option_value="$1"
			shift
			_kie_set_media_option "$argument" "$option_value" || return 1
			;;
		--wait) _KIE_MEDIA_WAIT=1 ;;
		--help | -h)
			_kie_show_media_help "$media_type" "$content_field"
			return 2
			;;
		--*)
			print_error "Unknown ${media_type} option: ${argument}"
			return 1
			;;
		*)
			if [[ -n "$_KIE_MEDIA_CONTENT" ]]; then
				_kie_report_unexpected_argument "$argument"
				return 1
			fi
			_KIE_MEDIA_CONTENT="$argument"
			;;
		esac
	done
	return 0
}

_kie_cmd_media() {
	local media_type="$1"
	local content_field="$2"
	shift 2
	local parse_rc=0
	_kie_parse_media_options "$media_type" "$content_field" "$@" || parse_rc=$?
	if [[ "$parse_rc" -eq 2 ]]; then
		return 0
	fi
	if [[ "$parse_rc" -ne 0 ]]; then
		return "$parse_rc"
	fi

	if [[ -z "$_KIE_MEDIA_MODEL" ]]; then
		print_error "--model is required"
		return 1
	fi
	if [[ -z "$_KIE_MEDIA_CONTENT" ]]; then
		print_error "${content_field} is required"
		return 1
	fi
	_kie_validate_positive_integer "$KIE_POLL_INTERVAL_LABEL" "$_KIE_MEDIA_INTERVAL" || return 1
	_kie_validate_positive_integer "$KIE_TIMEOUT_LABEL" "$_KIE_MEDIA_TIMEOUT" || return 1
	_kie_require_dependencies || return 1
	local base_input=""
	base_input=$(_kie_read_input_json "$_KIE_MEDIA_INLINE_INPUT" "$_KIE_MEDIA_INPUT_FILE") || return 1
	local merged_input=""
	merged_input=$(printf '%s' "$base_input" |
		jq -ce --arg field "$content_field" --arg value "$_KIE_MEDIA_CONTENT" '. + {($field): $value}')
	_kie_run_create "$_KIE_MEDIA_MODEL" "$merged_input" "$_KIE_MEDIA_CALLBACK" \
		"$_KIE_MEDIA_WAIT" "$_KIE_MEDIA_INTERVAL" "$_KIE_MEDIA_TIMEOUT" || return 1
	return 0
}

_kie_cmd_status() {
	local task_id=""
	if [[ $# -gt 0 ]]; then
		local task_value="$1"
		task_id="$task_value"
		shift
	fi
	if [[ -z "$task_id" || $# -gt 0 ]]; then
		print_error "Usage: kie-helper.sh status <task-id>"
		return 1
	fi
	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1
	local response=""
	if ! response=$(_kie_fetch_task_response "$task_id"); then
		print_error "Unable to query task ${task_id}"
		return 1
	fi
	_kie_api_response_ok "$response" || return 1
	printf '%s' "$response" | jq .
	return 0
}

_kie_cmd_wait() {
	local task_id=""
	local interval="$KIE_DEFAULT_POLL_INTERVAL"
	local timeout="$KIE_DEFAULT_TIMEOUT"
	local raw_output=0

	while [[ $# -gt 0 ]]; do
		local argument="$1"
		shift
		case "$argument" in
		--interval)
			[[ $# -gt 0 ]] || {
				print_error "--interval requires seconds"
				return 1
			}
			local interval_value="$1"
			interval="$interval_value"
			shift
			;;
		--timeout)
			[[ $# -gt 0 ]] || {
				print_error "--timeout requires seconds"
				return 1
			}
			local timeout_value="$1"
			timeout="$timeout_value"
			shift
			;;
		--raw) raw_output=1 ;;
		--help | -h)
			printf 'Usage: kie-helper.sh wait <task-id> [--interval N] [--timeout N] [--raw]\n'
			return 0
			;;
		--*)
			print_error "Unknown wait option: ${argument}"
			return 1
			;;
		*)
			if [[ -n "$task_id" ]]; then
				_kie_report_unexpected_argument "$argument"
				return 1
			fi
			task_id="$argument"
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		print_error "Task ID is required"
		return 1
	fi
	_kie_validate_positive_integer "$KIE_POLL_INTERVAL_LABEL" "$interval" || return 1
	_kie_validate_positive_integer "$KIE_TIMEOUT_LABEL" "$timeout" || return 1
	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1
	_kie_run_wait "$task_id" "$interval" "$timeout" "$raw_output" || return 1
	return 0
}

_kie_cmd_credits() {
	if [[ $# -gt 0 ]]; then
		print_error "Usage: kie-helper.sh credits"
		return 1
	fi
	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1
	local response=""
	if ! response=$(_kie_api_request GET "/api/v1/chat/credit"); then
		print_error "Unable to query Kie.ai credits"
		return 1
	fi
	_kie_api_response_ok "$response" || return 1
	printf '%s' "$response" | jq -r '.data'
	return 0
}

_kie_cmd_upload() {
	local file_path=""
	local upload_path="$KIE_DEFAULT_UPLOAD_PATH"
	local file_name=""

	while [[ $# -gt 0 ]]; do
		local argument="$1"
		shift
		case "$argument" in
		--path)
			[[ $# -gt 0 ]] || {
				print_error "--path requires a value"
				return 1
			}
			local path_value="$1"
			upload_path="$path_value"
			shift
			;;
		--name)
			[[ $# -gt 0 ]] || {
				print_error "--name requires a value"
				return 1
			}
			local name_value="$1"
			file_name="$name_value"
			shift
			;;
		--help | -h)
			printf 'Usage: kie-helper.sh upload <file> [--path storage/path] [--name filename.ext]\n'
			return 0
			;;
		--*)
			print_error "Unknown upload option: ${argument}"
			return 1
			;;
		*)
			if [[ -n "$file_path" ]]; then
				_kie_report_unexpected_argument "$argument"
				return 1
			fi
			file_path="$argument"
			;;
		esac
	done

	if [[ -z "$file_path" || ! -f "$file_path" ]]; then
		print_error "Upload file not found: ${file_path:-missing}"
		return 1
	fi
	if [[ -z "$upload_path" || "$upload_path" == /* || "$upload_path" == */ ]]; then
		print_error "Upload path must not start or end with a slash"
		return 1
	fi
	if [[ "$file_name" == */* ]]; then
		print_error "File name must not contain a path"
		return 1
	fi
	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1

	local -a curl_args=(
		--silent --show-error --request POST
		--connect-timeout "$KIE_CONNECT_TIMEOUT"
		--max-time "$KIE_REQUEST_TIMEOUT"
		"${KIE_UPLOAD_BASE}/api/file-stream-upload"
		--form "file=@${file_path}"
		--form-string "uploadPath=${upload_path}"
	)
	if [[ -n "$file_name" ]]; then
		curl_args+=(--form-string "fileName=${file_name}")
	fi
	local response=""
	if ! response=$(_kie_authenticated_curl "${curl_args[@]}"); then
		print_error "Unable to upload file to Kie.ai"
		return 1
	fi
	_kie_api_response_ok "$response" || return 1
	_kie_print_download_url "$response" || return 1
	return 0
}

_kie_cmd_upload_url() {
	local file_url=""
	local upload_path="$KIE_DEFAULT_UPLOAD_PATH"
	local file_name=""

	while [[ $# -gt 0 ]]; do
		local argument="$1"
		shift
		case "$argument" in
		--path)
			[[ $# -gt 0 ]] || {
				print_error "--path requires a value"
				return 1
			}
			local path_value="$1"
			upload_path="$path_value"
			shift
			;;
		--name)
			[[ $# -gt 0 ]] || {
				print_error "--name requires a value"
				return 1
			}
			local name_value="$1"
			file_name="$name_value"
			shift
			;;
		--help | -h)
			printf 'Usage: kie-helper.sh upload-url <URL> [--path storage/path] [--name filename.ext]\n'
			return 0
			;;
		--*)
			print_error "Unknown upload-url option: ${argument}"
			return 1
			;;
		*)
			if [[ -n "$file_url" ]]; then
				_kie_report_unexpected_argument "$argument"
				return 1
			fi
			file_url="$argument"
			;;
		esac
	done

	_kie_validate_http_url "File URL" "$file_url" || return 1
	if [[ -z "$upload_path" || "$upload_path" == /* || "$upload_path" == */ ]]; then
		print_error "Upload path must not start or end with a slash"
		return 1
	fi
	if [[ "$file_name" == */* ]]; then
		print_error "File name must not contain a path"
		return 1
	fi
	_kie_require_dependencies || return 1
	_kie_load_api_key || return 1

	local body=""
	if [[ -n "$file_name" ]]; then
		body=$(jq -cn --arg url "$file_url" --arg path "$upload_path" --arg name "$file_name" \
			'{fileUrl: $url, uploadPath: $path, fileName: $name}')
	else
		body=$(jq -cn --arg url "$file_url" --arg path "$upload_path" \
			'{fileUrl: $url, uploadPath: $path}')
	fi
	local response=""
	if ! response=$(_kie_authenticated_curl --silent --show-error --request POST \
		--connect-timeout "$KIE_CONNECT_TIMEOUT" \
		--max-time "$KIE_REQUEST_TIMEOUT" \
		"${KIE_UPLOAD_BASE}/api/file-url-upload" \
		--header "Content-Type: application/json" \
		--data "$body"); then
		print_error "Unable to upload URL to Kie.ai"
		return 1
	fi
	_kie_api_response_ok "$response" || return 1
	_kie_print_download_url "$response" || return 1
	return 0
}

_kie_cmd_catalog() {
	if [[ $# -gt 0 ]]; then
		print_error "Usage: kie-helper.sh catalog"
		return 1
	fi
	cat <<'EOF'
Kie.ai Market (current models and exact input schemas):
  https://kie.ai/market
  https://docs.kie.ai/market/quickstart

Representative model IDs:
  image  nano-banana-2
  video  kling-3.0/video
  audio  elevenlabs/text-to-speech-turbo-2-5

The catalog changes frequently. Copy the exact model ID and input object from
the model's documentation, then pass that object with --params or --input-file.
EOF
	return 0
}

_kie_show_create_help() {
	cat <<'EOF'
Usage: kie-helper.sh create --model ID [options]

Options:
  --params JSON       Model-specific input object (default: {})
  --input-file FILE   Read the model-specific input object from a JSON file
  --callback URL      Receive completion callbacks instead of polling
  --wait              Poll until the task succeeds or fails
  --interval SECONDS  Initial polling interval (default: 3)
  --timeout SECONDS   Maximum polling time (default: 900)
EOF
	return 0
}

_kie_show_media_help() {
	local media_type="$1"
	local content_field="$2"
	cat <<EOF
Usage: kie-helper.sh ${media_type} --model ID --${content_field} VALUE [options]

The convenience command merges --${content_field} into the model-specific
object supplied through --params or --input-file. It accepts the same callback,
wait, interval, and timeout options as create.
EOF
	return 0
}

_kie_show_help() {
	cat <<'EOF'
Kie.ai Helper - generic client for Kie.ai Market generation APIs

Usage: kie-helper.sh <command> [arguments] [options]

Commands:
  create, generate   Submit any model with a model-specific JSON input object
  image              Submit an image model and merge a prompt into its input
  video              Submit a video model and merge a prompt into its input
  audio              Submit an audio model and merge text into its input
  status             Print the current task record as JSON
  wait               Poll with bounded exponential backoff and print results
  credits            Print remaining account credits
  upload             Upload a local file and print its temporary URL
  upload-url         Import a public URL and print its temporary Kie.ai URL
  catalog            Show current model-discovery links and examples
  help               Show this help

Examples:
  kie-helper.sh create --model nano-banana-2 \
    --params '{"prompt":"Editorial product photo","aspect_ratio":"16:9"}'
  kie-helper.sh image --model nano-banana-2 --prompt "Editorial product photo" \
    --params '{"resolution":"2K"}' --wait
  kie-helper.sh video --model kling-3.0/video --prompt "Slow camera push-in" \
    --params '{"duration":"5","aspect_ratio":"16:9","mode":"pro","sound":true,"multi_shots":false,"multi_prompt":[]}'
  kie-helper.sh audio --model elevenlabs/text-to-speech-turbo-2-5 \
    --text "Welcome" --params '{"voice":"Rachel"}'
  kie-helper.sh status TASK_ID
  kie-helper.sh wait TASK_ID --timeout 900
  kie-helper.sh upload reference.png --path aidevops/references
  kie-helper.sh credits

Environment:
  KIE_API_KEY         Required Bearer token; store with aidevops secret
  KIE_API_BASE        Optional API base override for testing
  KIE_UPLOAD_BASE     Optional upload API base override for testing
EOF
	return 0
}

main() {
	local command="help"
	if [[ $# -gt 0 ]]; then
		local command_value="$1"
		command="$command_value"
		shift
	fi

	case "$command" in
	create | generate) _kie_cmd_create "$@" || return 1 ;;
	image) _kie_cmd_media "image" "$KIE_PROMPT_FIELD" "$@" || return 1 ;;
	video) _kie_cmd_media "video" "$KIE_PROMPT_FIELD" "$@" || return 1 ;;
	audio) _kie_cmd_media "audio" "text" "$@" || return 1 ;;
	status) _kie_cmd_status "$@" || return 1 ;;
	wait) _kie_cmd_wait "$@" || return 1 ;;
	credits | balance) _kie_cmd_credits "$@" || return 1 ;;
	upload) _kie_cmd_upload "$@" || return 1 ;;
	upload-url) _kie_cmd_upload_url "$@" || return 1 ;;
	catalog | models) _kie_cmd_catalog "$@" || return 1 ;;
	help | --help | -h) _kie_show_help || return 1 ;;
	*)
		print_error "Unknown command: ${command}"
		_kie_show_help
		return 1
		;;
	esac
	return 0
}

main "$@"
