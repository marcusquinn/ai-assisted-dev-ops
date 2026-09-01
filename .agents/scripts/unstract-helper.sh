#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# Unstract Helper - Self-hosted document processing platform
# Manages local Unstract instance via Docker Compose
#
# Usage: unstract-helper.sh [install|start|stop|status|logs|uninstall|configure-llm]

# Source shared constants (provides sed_inplace, print_*, color constants)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Constants
readonly UNSTRACT_DIR="${HOME}/.aidevops/unstract"
readonly UNSTRACT_REPO="https://github.com/Zipstack/unstract.git"
readonly CREDENTIALS_CONFIG_DIR="${HOME}/.config/aidevops"
readonly CREDENTIALS_FILE="${HOME}/.config/aidevops/credentials.sh"
readonly CREDENTIAL_STORE_HELPER="${SCRIPT_DIR}/atomic-env-store.py"
readonly FRONTEND_URL="http://frontend.unstract.localhost"
readonly BACKEND_URL="http://backend.unstract.localhost"

# Check prerequisites
check_prerequisites() {
	local missing=0

	if ! command -v docker &>/dev/null; then
		print_error "Docker is required but not installed"
		print_info "Install from: https://docs.docker.com/get-docker/"
		missing=1
	fi

	if ! command -v docker compose &>/dev/null && ! command -v docker-compose &>/dev/null; then
		print_error "Docker Compose is required but not installed"
		missing=1
	fi

	if ! command -v git &>/dev/null; then
		print_error "Git is required but not installed"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi

	# Check available RAM (minimum 8GB)
	local ram_gb
	if [[ "$(uname)" == "Darwin" ]]; then
		ram_gb=$(($(sysctl -n hw.memsize) / 1073741824))
	else
		ram_gb=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1048576))
	fi

	if [[ "$ram_gb" -lt 8 ]]; then
		print_warning "System has ${ram_gb}GB RAM. Unstract recommends 8GB minimum."
	else
		print_info "System RAM: ${ram_gb}GB (meets 8GB minimum)"
	fi

	return 0
}

# Install Unstract self-hosted
do_install() {
	print_info "Installing Unstract self-hosted platform..."

	if [[ -d "$UNSTRACT_DIR" ]]; then
		print_warning "Unstract already installed at ${UNSTRACT_DIR}"
		print_info "Use 'unstract-helper.sh start' to start, or 'unstract-helper.sh uninstall' first"
		return 0
	fi

	check_prerequisites || return 1

	# Clone repository
	print_info "Cloning Unstract repository..."
	git clone "$UNSTRACT_REPO" "$UNSTRACT_DIR"

	# Disable analytics in frontend
	local frontend_env="${UNSTRACT_DIR}/frontend/.env"
	if [[ -f "$frontend_env" ]]; then
		if grep -q "REACT_APP_ENABLE_POSTHOG" "$frontend_env"; then
			sed_inplace 's/REACT_APP_ENABLE_POSTHOG=.*/REACT_APP_ENABLE_POSTHOG=false/' "$frontend_env"
		else
			echo "REACT_APP_ENABLE_POSTHOG=false" >>"$frontend_env"
		fi
	else
		echo "REACT_APP_ENABLE_POSTHOG=false" >"$frontend_env"
	fi
	print_success "Analytics disabled (REACT_APP_ENABLE_POSTHOG=false)"

	# Start the platform
	do_start

	# Configure MCP env to point to local instance
	configure_local_mcp_env

	print_success "Unstract self-hosted installation complete!"
	echo
	print_info "Next steps:"
	print_info "1. Visit ${FRONTEND_URL} (login: unstract/unstract)"
	print_info "2. Add LLM adapters (Settings > Adapters) using your existing API keys"
	print_info "3. Create a Prompt Studio project and deploy as API"
	print_info "4. The MCP will automatically connect to your local instance"
	echo
	print_info "Run 'unstract-helper.sh configure-llm' for help adding LLM keys"

	return 0
}

# Start Unstract
do_start() {
	if [[ ! -d "$UNSTRACT_DIR" ]]; then
		print_error "Unstract not installed. Run 'unstract-helper.sh install' first"
		return 1
	fi

	print_info "Starting Unstract platform..."
	cd "$UNSTRACT_DIR" || exit

	if [[ -f "run-platform.sh" ]]; then
		bash run-platform.sh
	else
		docker compose up -d
	fi

	# Wait for services to be ready
	print_info "Waiting for services to start..."
	local attempts=0
	while [[ $attempts -lt 30 ]]; do
		if curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null | grep -q "200\|301\|302"; then
			print_success "Unstract is running at ${FRONTEND_URL}"
			return 0
		fi
		sleep 2
		attempts=$((attempts + 1))
	done

	print_warning "Services may still be starting. Check: unstract-helper.sh status"
	return 0
}

# Stop Unstract
do_stop() {
	if [[ ! -d "$UNSTRACT_DIR" ]]; then
		print_error "Unstract not installed"
		return 1
	fi

	print_info "Stopping Unstract platform..."
	cd "$UNSTRACT_DIR" || exit
	docker compose down
	print_success "Unstract stopped"
	return 0
}

# Check status
do_status() {
	if [[ ! -d "$UNSTRACT_DIR" ]]; then
		print_info "Unstract: Not installed"
		print_info "Run 'unstract-helper.sh install' to set up"
		return 0
	fi

	print_info "Unstract installation: ${UNSTRACT_DIR}"

	cd "$UNSTRACT_DIR" || exit
	local running
	running=$(docker compose ps --format json 2>/dev/null | safe_grep_count '"running"')

	if [[ "$running" -gt 0 ]]; then
		print_success "Unstract: Running (${running} containers)"
		print_info "Frontend: ${FRONTEND_URL}"
		print_info "Backend: ${BACKEND_URL}"
	else
		print_warning "Unstract: Installed but not running"
		print_info "Run 'unstract-helper.sh start' to start"
	fi

	# Check MCP env
	if [[ -f "$CREDENTIALS_FILE" ]] && grep -q "API_BASE_URL" "$CREDENTIALS_FILE"; then
		local url
		url=$(grep "^export API_BASE_URL" "$CREDENTIALS_FILE" | sed 's/.*=//' | tr -d '"' | tr -d "'")
		print_info "MCP configured: ${url}"
	else
		print_warning "MCP not configured. Run 'unstract-helper.sh configure-llm'"
	fi

	return 0
}

# Show logs
do_logs() {
	if [[ ! -d "$UNSTRACT_DIR" ]]; then
		print_error "Unstract not installed"
		return 1
	fi

	cd "$UNSTRACT_DIR" || exit
	local service="${1:-}"
	if [[ -n "$service" ]]; then
		docker compose logs -f "$service"
	else
		docker compose logs -f --tail=50
	fi
	return 0
}

# Uninstall
do_uninstall() {
	if [[ ! -d "$UNSTRACT_DIR" ]]; then
		print_info "Unstract not installed, nothing to remove"
		return 0
	fi

	print_warning "This will stop and remove the Unstract installation"
	print_warning "Location: ${UNSTRACT_DIR}"
	echo -n "Continue? [y/N] "
	read -r confirm
	if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
		print_info "Cancelled"
		return 0
	fi

	cd "$UNSTRACT_DIR" || exit
	docker compose down -v 2>/dev/null || true
	cd "$HOME" || exit
	rm -rf "$UNSTRACT_DIR"

	# Remove MCP env entries
	python3 "$CREDENTIAL_STORE_HELPER" remove-active --config-dir "$CREDENTIALS_CONFIG_DIR" \
		--name UNSTRACT_API_KEY >/dev/null || return 1
	python3 "$CREDENTIAL_STORE_HELPER" remove-active-if-contains --config-dir "$CREDENTIALS_CONFIG_DIR" \
		--name API_BASE_URL --contains unstract >/dev/null || return 1

	print_success "Unstract uninstalled"
	return 0
}

# Configure local MCP environment
configure_local_mcp_env() {
	local url_action=""
	local key_action=""
	url_action=$(printf '%s' 'http://backend.unstract.localhost/deployment/api/YOUR_DEPLOYMENT_ID/' | \
		python3 "$CREDENTIAL_STORE_HELPER" add-active-if-missing --config-dir "$CREDENTIALS_CONFIG_DIR" \
			--name API_BASE_URL) || return 1
	key_action=$(printf '%s' 'YOUR_LOCAL_API_KEY' | python3 "$CREDENTIAL_STORE_HELPER" add-active-if-missing \
		--config-dir "$CREDENTIALS_CONFIG_DIR" --name UNSTRACT_API_KEY) || return 1

	if [[ "$url_action" == "added" || "$key_action" == "added" ]]; then
		print_info "Added missing Unstract settings to the active credential store"
		print_warning "Update these after creating your first API deployment in Prompt Studio"
	fi

	return 0
}

# Help with LLM adapter configuration
do_configure_llm() {
	print_info "Unstract LLM Adapter Configuration"
	echo
	print_info "Unstract uses 'Adapters' to connect to LLM providers."
	print_info "Add these in the Unstract UI: Settings > Adapters > Add Adapter"
	echo
	print_info "Your existing API keys from ~/.config/aidevops/credentials.sh can be used:"
	echo

	# Check which keys the user already has
	local found_keys=0
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		if grep -q "OPENAI_API_KEY" "$CREDENTIALS_FILE" 2>/dev/null; then
			print_success "OpenAI API key found - add as 'OpenAI' adapter in Unstract"
			found_keys=$((found_keys + 1))
		fi
		if grep -q "ANTHROPIC_API_KEY" "$CREDENTIALS_FILE" 2>/dev/null; then
			print_success "Anthropic API key found - add as 'Anthropic' adapter in Unstract"
			found_keys=$((found_keys + 1))
		fi
		if grep -q "GOOGLE_API_KEY\|GOOGLE_APPLICATION_CREDENTIALS\|VERTEX" "$CREDENTIALS_FILE" 2>/dev/null; then
			print_success "Google/Vertex AI key found - add as 'Google VertexAI' adapter"
			found_keys=$((found_keys + 1))
		fi
		if grep -q "AZURE_OPENAI" "$CREDENTIALS_FILE" 2>/dev/null; then
			print_success "Azure OpenAI key found - add as 'Azure OpenAI' adapter"
			found_keys=$((found_keys + 1))
		fi
		if grep -q "AWS_ACCESS_KEY\|AWS_SECRET" "$CREDENTIALS_FILE" 2>/dev/null; then
			print_success "AWS credentials found - add as 'Bedrock' adapter"
			found_keys=$((found_keys + 1))
		fi
	fi

	if [[ "$found_keys" -eq 0 ]]; then
		print_warning "No LLM API keys found in ${CREDENTIALS_FILE}"
		print_info "Add at least one LLM key to use Unstract:"
		echo
	fi

	echo
	print_info "Supported LLM providers in Unstract:"
	print_info "  - OpenAI (GPT-4, GPT-4o)"
	print_info "  - Anthropic (Claude)"
	print_info "  - Google VertexAI / Gemini"
	print_info "  - Azure OpenAI"
	print_info "  - AWS Bedrock"
	print_info "  - Ollama (local, no API key needed)"
	print_info "  - Mistral AI"
	echo
	print_info "For Ollama (fully local, no cloud):"
	print_info "  1. Install Ollama: https://ollama.ai"
	print_info "  2. Pull a model: ollama pull llama3"
	print_info "  3. Add as 'Ollama' adapter in Unstract (URL: http://host.docker.internal:11434)"
	echo
	print_info "Visit ${FRONTEND_URL} > Settings > Adapters to configure"

	return 0
}

# Main
main() {
	local command="${1:-help}"

	case "$command" in
	install) do_install ;;
	start) do_start ;;
	stop) do_stop ;;
	status) do_status ;;
	logs)
		shift
		do_logs "${1:-}"
		;;
	uninstall) do_uninstall ;;
	configure-llm) do_configure_llm ;;
	help | --help | -h)
		echo "Usage: unstract-helper.sh [command]"
		echo
		echo "Commands:"
		echo "  install        Clone and start Unstract self-hosted (analytics disabled)"
		echo "  start          Start Unstract containers"
		echo "  stop           Stop Unstract containers"
		echo "  status         Show installation and running status"
		echo "  logs [svc]     Show container logs (optionally for specific service)"
		echo "  uninstall      Remove Unstract installation and data"
		echo "  configure-llm  Show how to add LLM adapters using your existing API keys"
		echo
		echo "Prerequisites: Docker, Docker Compose, Git, 8GB RAM"
		echo "Install location: ${UNSTRACT_DIR}"
		;;
	*)
		print_error "Unknown command: ${command}"
		echo "Run 'unstract-helper.sh help' for usage"
		return 1
		;;
	esac

	return 0
}

main "$@"
