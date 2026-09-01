#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2129
set -euo pipefail

# WaterCrawl Helper Script
# Modern web crawling framework for LLM-ready data extraction
#
# SELF-HOSTED FIRST: This script prioritizes self-hosted deployment over cloud API.
# WaterCrawl can be deployed locally via Docker or on VPS/Cloudron.
#
# WaterCrawl transforms web content into structured, AI-ready data with:
# - Smart crawling with depth/domain/path controls
# - Web search engine integration
# - Sitemap generation and analysis
# - JavaScript rendering with screenshots
# - AI-powered content processing (OpenAI integration)
# - Extensible plugin system
#
# Usage: ./watercrawl-helper.sh [command] [options]
# Commands:
#   docker-setup    - Clone repo and prepare Docker deployment (RECOMMENDED)
#   docker-start    - Start WaterCrawl Docker containers
#   docker-stop     - Stop WaterCrawl Docker containers
#   docker-logs     - View Docker container logs
#   coolify-deploy  - Deploy to Coolify (self-hosted PaaS)
#   setup           - Install Node.js SDK (for API access)
#   status          - Check WaterCrawl configuration and connectivity
#   scrape          - Scrape a single URL
#   crawl           - Crawl a website with depth control
#   search          - Search the web using WaterCrawl's search engine
#   sitemap         - Generate sitemap for a website
#   api-key         - Configure WaterCrawl API key
#   api-url         - Configure custom API URL (for self-hosted)
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Source shared constants (provides sed_inplace and other utilities)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" || true
readonly CREDENTIAL_STORE_HELPER="${SCRIPT_DIR}/atomic-env-store.py"

# Fallback if shared-constants.sh not loaded
if ! declare -f ensure_credentials_file &>/dev/null; then
	ensure_credentials_file() {
		local f="$1"
		mkdir -p "$(dirname "$f")"
		chmod 700 "$(dirname "$f")" 2>/dev/null || true
		[[ ! -f "$f" ]] && : >"$f"
		chmod 600 "$f" 2>/dev/null || true
	}
fi

# Colors for output (fallback if shared-constants.sh not loaded)
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${PURPLE+x}" ]] && PURPLE='\033[0;35m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Common constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
readonly HELP_SHOW_MESSAGE="Show this help message"

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly CONFIG_DIR="$SCRIPT_DIR/../configs"
readonly CREDENTIALS_CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$HOME/.config/aidevops/credentials.sh"
readonly WATERCRAWL_CLOUD_URL="https://app.watercrawl.dev"
readonly WATERCRAWL_LOCAL_URL="http://localhost"
readonly NPM_PACKAGE="@watercrawl/nodejs"
readonly WATERCRAWL_REPO="https://github.com/watercrawl/WaterCrawl.git"
readonly WATERCRAWL_DIR="$HOME/.aidevops/watercrawl"

print_success() {
	local message="$1"
	echo -e "${GREEN}[OK] $message${NC}"
	return 0
}

print_info() {
	local message="$1"
	echo -e "${BLUE}[INFO] $message${NC}"
	return 0
}

print_warning() {
	local message="$1"
	echo -e "${YELLOW}[WARN] $message${NC}"
	return 0
}

print_error() {
	local message="$1"
	echo -e "${RED}[ERROR] $message${NC}" >&2
	return 0
}

print_header() {
	local message="$1"
	echo -e "${PURPLE}=== $message ===${NC}"
	return 0
}

# Load configuration from credentials.sh
load_config() {
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		# shellcheck source=/dev/null
		source "$CREDENTIALS_FILE"
	fi

	# Default to local URL if self-hosted, otherwise cloud
	if [[ -z "${WATERCRAWL_API_URL:-}" ]]; then
		if [[ -d "${WATERCRAWL_DIR:-}" ]] && docker ps -q -f name=watercrawl 2>/dev/null | grep -q .; then
			WATERCRAWL_API_URL="$WATERCRAWL_LOCAL_URL"
		else
			WATERCRAWL_API_URL="$WATERCRAWL_CLOUD_URL"
		fi
	fi

	return 0
}

# Load API key from credentials.sh
load_api_key() {
	load_config

	if [[ -z "${WATERCRAWL_API_KEY:-}" ]]; then
		return 1
	fi

	return 0
}

# Check if Docker is available
check_docker() {
	if ! command -v docker &>/dev/null; then
		print_error "Docker is not installed. Please install Docker first."
		return 1
	fi

	if ! docker info &>/dev/null; then
		print_error "Docker daemon is not running. Please start Docker."
		return 1
	fi

	return 0
}

# Check if Node.js is available
check_node() {
	if ! command -v node &>/dev/null; then
		print_error "Node.js is not installed. Please install Node.js 14+ first."
		return 1
	fi

	local node_version
	node_version=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
	if [[ -z "$node_version" ]] || ! [[ "$node_version" =~ ^[0-9]+$ ]]; then
		print_error "Could not determine Node.js version"
		return 1
	fi

	if [[ "$node_version" -lt 14 ]]; then
		print_error "Node.js 14+ is required. Current version: $(node -v)"
		return 1
	fi

	return 0
}

# Check if npm package is installed
check_npm_package() {
	if npm list -g "$NPM_PACKAGE" &>/dev/null; then
		return 0
	fi

	if npm list "$NPM_PACKAGE" &>/dev/null 2>&1; then
		return 0
	fi

	return 1
}

# Setup Docker deployment (RECOMMENDED)
docker_setup() {
	print_header "Setting up WaterCrawl Self-Hosted (Docker)"

	if ! check_docker; then
		return 1
	fi

	# Create directory
	mkdir -p "$WATERCRAWL_DIR"

	# Clone or update repository
	if [[ -d "$WATERCRAWL_DIR/.git" ]]; then
		print_info "Updating existing WaterCrawl installation..."
		cd "$WATERCRAWL_DIR" || return 1
		git pull origin main
	else
		print_info "Cloning WaterCrawl repository..."
		git clone "$WATERCRAWL_REPO" "$WATERCRAWL_DIR"
		cd "$WATERCRAWL_DIR" || return 1
	fi

	# Setup environment file
	if [[ ! -f "$WATERCRAWL_DIR/docker/.env" ]]; then
		print_info "Creating environment configuration..."
		cp "$WATERCRAWL_DIR/docker/.env.example" "$WATERCRAWL_DIR/docker/.env"

		# Generate secure keys
		local secret_key
		secret_key=$(openssl rand -hex 32)
		local api_encryption_key
		api_encryption_key=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)

		# Update .env with secure values
		sed_inplace "s|SECRET_KEY=.*|SECRET_KEY=$secret_key|" "$WATERCRAWL_DIR/docker/.env"
		sed_inplace "s|API_ENCRYPTION_KEY=.*|API_ENCRYPTION_KEY=$api_encryption_key|" "$WATERCRAWL_DIR/docker/.env"

		print_success "Environment file created with secure keys"
	else
		print_info "Environment file already exists"
	fi

	print_success "WaterCrawl Docker setup complete!"
	print_info ""
	print_info "Next steps:"
	print_info "1. Review config: $WATERCRAWL_DIR/docker/.env"
	print_info "2. Start services: $0 docker-start"
	print_info "3. Create admin user: $0 docker-admin"
	print_info "4. Access dashboard: http://localhost"
	print_info ""
	print_info "For production deployment on a domain, update these in .env:"
	print_info "  MINIO_EXTERNAL_ENDPOINT=your-domain.com"
	print_info "  MINIO_BROWSER_REDIRECT_URL=https://your-domain.com/minio-console/"
	print_info "  MINIO_SERVER_URL=https://your-domain.com/"

	return 0
}

# Start Docker containers
docker_start() {
	print_header "Starting WaterCrawl Docker Containers"

	if ! check_docker; then
		return 1
	fi

	if [[ ! -d "$WATERCRAWL_DIR/docker" ]]; then
		print_error "WaterCrawl not installed. Run: $0 docker-setup"
		return 1
	fi

	cd "$WATERCRAWL_DIR/docker" || return 1

	print_info "Starting services..."
	if docker compose up -d; then
		print_success "WaterCrawl started successfully!"
		print_info ""
		print_info "Services available at:"
		print_info "  Frontend: http://localhost"
		print_info "  API: http://localhost/api"
		print_info "  MinIO Console: http://localhost/minio-console"
		print_info ""
		print_info "View logs: $0 docker-logs"

		# Update API URL to local
		configure_api_url "$WATERCRAWL_LOCAL_URL"
	else
		print_error "Failed to start WaterCrawl"
		return 1
	fi

	return 0
}

# Stop Docker containers
docker_stop() {
	print_header "Stopping WaterCrawl Docker Containers"

	if ! check_docker; then
		return 1
	fi

	if [[ ! -d "$WATERCRAWL_DIR/docker" ]]; then
		print_error "WaterCrawl not installed"
		return 1
	fi

	cd "$WATERCRAWL_DIR/docker" || return 1

	if docker compose down; then
		print_success "WaterCrawl stopped"
	else
		print_error "Failed to stop WaterCrawl"
		return 1
	fi

	return 0
}

# View Docker logs
docker_logs() {
	local service="$1"

	if ! check_docker; then
		return 1
	fi

	if [[ ! -d "$WATERCRAWL_DIR/docker" ]]; then
		print_error "WaterCrawl not installed"
		return 1
	fi

	cd "$WATERCRAWL_DIR/docker" || return 1

	if [[ -n "$service" ]]; then
		docker compose logs -f "$service"
	else
		docker compose logs -f
	fi

	return 0
}

# Create admin user
docker_admin() {
	print_header "Creating WaterCrawl Admin User"

	if ! check_docker; then
		return 1
	fi

	if [[ ! -d "$WATERCRAWL_DIR/docker" ]]; then
		print_error "WaterCrawl not installed"
		return 1
	fi

	cd "$WATERCRAWL_DIR/docker" || return 1

	print_info "Creating superuser (follow prompts)..."
	docker compose exec app python manage.py createsuperuser

	return 0
}

# Deploy to Coolify
coolify_deploy() {
	print_header "Deploying WaterCrawl to Coolify"

	print_info "WaterCrawl can be deployed to Coolify as a Docker Compose application."
	print_info ""
	print_info "Steps:"
	print_info "1. In Coolify, create a new 'Docker Compose' resource"
	print_info "2. Use Git repository: $WATERCRAWL_REPO"
	print_info "3. Set Docker Compose path: docker/docker-compose.yml"
	print_info "4. Configure environment variables in Coolify:"
	print_info "   - SECRET_KEY (generate secure key)"
	print_info "   - API_ENCRYPTION_KEY (generate secure key)"
	print_info "   - MINIO_EXTERNAL_ENDPOINT (your domain)"
	print_info "   - FRONTEND_URL (https://your-domain.com)"
	print_info "5. Set up domain/SSL in Coolify"
	print_info "6. Deploy!"
	print_info ""
	print_info "For detailed Coolify deployment, see:"
	print_info "  https://docs.watercrawl.dev/self-hosted/installation"
	print_info ""
	print_info "Or use coolify-helper.sh for automated deployment:"
	print_info "  bash .agents/scripts/coolify-helper.sh deploy watercrawl"

	return 0
}

# Setup Node.js SDK (for API access)
setup_sdk() {
	print_header "Setting up WaterCrawl Node.js SDK"

	if ! check_node; then
		return 1
	fi

	print_info "Installing WaterCrawl Node.js SDK..."
	if npm install -g "$NPM_PACKAGE"; then
		print_success "WaterCrawl SDK installed successfully"
	else
		print_warning "Global install failed, trying local install..."
		if npm install "$NPM_PACKAGE"; then
			print_success "WaterCrawl SDK installed locally"
		else
			print_error "Failed to install WaterCrawl SDK"
			return 1
		fi
	fi

	# Check for API key
	if ! load_api_key; then
		print_warning "WaterCrawl API key not configured"
		print_info ""
		print_info "For self-hosted: Create user at http://localhost, get API key from dashboard"
		print_info "For cloud API: Get key from https://app.watercrawl.dev"
		print_info ""
		print_info "Then run: $0 api-key YOUR_API_KEY"
	else
		print_success "API key already configured"
	fi

	return 0
}

# Configure API key
configure_api_key() {
	local api_key="$1"

	if [[ -z "$api_key" ]]; then
		print_error "API key is required"
		print_info "Usage: $0 api-key YOUR_API_KEY"
		print_info ""
		print_info "For self-hosted: Get key from http://localhost dashboard"
		print_info "For cloud API: Get key from https://app.watercrawl.dev"
		return 1
	fi

	print_header "Configuring WaterCrawl API Key"

	printf '%s' "$api_key" | python3 "$CREDENTIAL_STORE_HELPER" upsert-active \
		--config-dir "$CREDENTIALS_CONFIG_DIR" --name WATERCRAWL_API_KEY >/dev/null || return 1
	print_success "WaterCrawl API key updated in the active credential store"

	return 0
}

# Configure custom API URL (for self-hosted)
configure_api_url() {
	local api_url="$1"

	if [[ -z "$api_url" ]]; then
		print_error "API URL is required"
		print_info "Usage: $0 api-url http://your-watercrawl-instance.com"
		return 1
	fi

	print_header "Configuring WaterCrawl API URL"

	printf '%s' "$api_url" | python3 "$CREDENTIAL_STORE_HELPER" upsert-active \
		--config-dir "$CREDENTIALS_CONFIG_DIR" --name WATERCRAWL_API_URL >/dev/null || return 1
	print_success "WaterCrawl API URL updated in the active credential store"

	return 0
}

# Check status
check_status() {
	print_header "WaterCrawl Status"

	load_config

	# Check Docker installation
	if [[ -d "$WATERCRAWL_DIR" ]]; then
		print_success "Self-hosted: Installed at $WATERCRAWL_DIR"

		if check_docker 2>/dev/null; then
			cd "$WATERCRAWL_DIR/docker" 2>/dev/null || true
			if docker compose ps 2>/dev/null | grep -q "Up"; then
				print_success "Docker: Running"
				docker compose ps 2>/dev/null | grep -E "NAME|watercrawl" || true
			else
				print_warning "Docker: Not running (run: $0 docker-start)"
			fi
		fi
	else
		print_info "Self-hosted: Not installed (run: $0 docker-setup)"
	fi

	# Check Node.js SDK
	if check_node 2>/dev/null; then
		print_success "Node.js: $(node -v)"
		if check_npm_package; then
			local version
			version=$(npm list -g "$NPM_PACKAGE" 2>/dev/null | grep "$NPM_PACKAGE" | sed 's/.*@//' || echo "installed")
			print_success "SDK: $NPM_PACKAGE@$version"
		else
			print_info "SDK: Not installed (run: $0 setup)"
		fi
	else
		print_warning "Node.js: Not available"
	fi

	# Check API configuration
	print_info "API URL: ${WATERCRAWL_API_URL:-not configured}"

	if [[ -n "${WATERCRAWL_API_KEY:-}" ]]; then
		print_success "API Key: Configured"

		# Test API connectivity
		local response
		response=$(curl -s -o /dev/null -w "%{http_code}" \
			-H "Authorization: Bearer ${WATERCRAWL_API_KEY:-}" \
			"${WATERCRAWL_API_URL:-}/api/v1/core/crawl-requests/" 2>/dev/null)

		if [[ "$response" == "200" ]]; then
			print_success "API: Connected"
		elif [[ "$response" == "000" ]]; then
			print_warning "API: Cannot connect to ${WATERCRAWL_API_URL:-}"
		else
			print_warning "API: HTTP $response"
		fi
	else
		print_warning "API Key: Not configured (run: $0 api-key YOUR_KEY)"
	fi

	print_info ""
	print_info "Self-hosted docs: https://docs.watercrawl.dev/self-hosted/"
	print_info "Cloud dashboard: https://app.watercrawl.dev"

	return 0
}

# Scrape a single URL
scrape_url() {
	local url="$1"
	local output_file="$2"

	if [[ -z "$url" ]]; then
		print_error "URL is required"
		print_info "Usage: $0 scrape <url> [output.json]"
		return 1
	fi

	if ! load_api_key; then
		print_error "API key not configured"
		print_info "Run: $0 api-key YOUR_API_KEY"
		return 1
	fi

	print_header "Scraping: $url"
	print_info "Using API: ${WATERCRAWL_API_URL:-}"

	# Create Node.js script for scraping
	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local temp_dir temp_script
	temp_dir=$(mktemp -d /tmp/watercrawl_scrape_XXXXXX)
	temp_script="$temp_dir/script.mjs"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -rf '${temp_dir}'"

	cat >"$temp_script" <<'SCRIPT'
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const apiKey = process.env.WATERCRAWL_API_KEY;
const apiUrl = process.env.WATERCRAWL_API_URL;
const url = process.argv[2];

if (!apiKey) {
    console.error('Error: WATERCRAWL_API_KEY not set');
    process.exit(1);
}

if (!url) {
    console.error('Error: URL required');
    process.exit(1);
}

const client = new WaterCrawlAPIClient(apiKey, apiUrl);

try {
    console.error('Scraping URL...');
    const result = await client.scrapeUrl(url, {
        only_main_content: true,
        include_links: true,
        wait_time: 2000
    });
    
    console.log(JSON.stringify(result, null, 2));
} catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
}
SCRIPT

	local result
	if result=$(WATERCRAWL_API_KEY="${WATERCRAWL_API_KEY:-}" WATERCRAWL_API_URL="${WATERCRAWL_API_URL:-}" node "$temp_script" "$url" 2>&1); then
		if [[ -n "$output_file" ]]; then
			echo "$result" >"$output_file"
			print_success "Results saved to: $output_file"
		else
			echo "$result"
		fi
		print_success "Scrape completed"
	else
		print_error "Scrape failed: $result"
		rm -rf "$temp_dir"
		return 1
	fi

	rm -rf "$temp_dir"
	return 0
}

# Write the Node.js crawl script to a temp file
_crawl_write_script() {
	local temp_script="$1"
	cat >"$temp_script" <<'SCRIPT'
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const apiKey = process.env.WATERCRAWL_API_KEY;
const apiUrl = process.env.WATERCRAWL_API_URL;
const url = process.argv[2];
const maxDepth = parseInt(process.argv[3]) || 2;
const pageLimit = parseInt(process.argv[4]) || 50;

if (!apiKey) {
    console.error('Error: WATERCRAWL_API_KEY not set');
    process.exit(1);
}

if (!url) {
    console.error('Error: URL required');
    process.exit(1);
}

const client = new WaterCrawlAPIClient(apiKey, apiUrl);

try {
    console.error(`Creating crawl request (depth: ${maxDepth}, limit: ${pageLimit})...`);
    const crawlRequest = await client.createCrawlRequest(
        url,
        { max_depth: maxDepth, page_limit: pageLimit },
        { only_main_content: true, include_links: true, wait_time: 2000 }
    );
    console.error(`Crawl started: ${crawlRequest.uuid}`);
    console.error('Monitoring progress...');
    const results = [];
    for await (const event of client.monitorCrawlRequest(crawlRequest.uuid)) {
        if (event.type === 'state') {
            console.error(`Status: ${event.data.status}, Pages: ${event.data.number_of_documents}`);
        } else if (event.type === 'result') {
            results.push({ url: event.data.url, title: event.data.title, content: event.data.result });
            console.error(`Crawled: ${event.data.url}`);
        }
    }
    console.log(JSON.stringify({ crawl_id: crawlRequest.uuid, total_pages: results.length, results: results }, null, 2));
} catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
}
SCRIPT
	return 0
}

# Handle crawl output: filter progress lines and write to file or stdout
_crawl_handle_output() {
	local result="$1"
	local output_file="$2"
	local filtered
	filtered=$(printf '%s\n' "$result" | grep -v "^\(Status:\|Crawled:\|Creating\|Crawl started\|Monitoring\)")
	if [[ -n "$output_file" ]]; then
		printf '%s\n' "$filtered" >"$output_file"
		print_success "Results saved to: $output_file"
	else
		printf '%s\n' "$filtered"
	fi
	return 0
}

# Crawl a website
crawl_website() {
	local url="$1"
	local max_depth="${2:-2}"
	local page_limit="${3:-50}"
	local output_file="$4"

	if [[ -z "$url" ]]; then
		print_error "URL is required"
		print_info "Usage: $0 crawl <url> [max_depth] [page_limit] [output.json]"
		return 1
	fi

	if ! load_api_key; then
		print_error "API key not configured"
		print_info "Run: $0 api-key YOUR_API_KEY"
		return 1
	fi

	print_header "Crawling: $url"
	print_info "Using API: ${WATERCRAWL_API_URL:-}"
	print_info "Max depth: $max_depth, Page limit: $page_limit"

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local temp_dir temp_script
	temp_dir=$(mktemp -d /tmp/watercrawl_crawl_XXXXXX)
	temp_script="$temp_dir/script.mjs"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -rf '${temp_dir}'"

	_crawl_write_script "$temp_script"

	local result
	if result=$(WATERCRAWL_API_KEY="${WATERCRAWL_API_KEY:-}" WATERCRAWL_API_URL="${WATERCRAWL_API_URL:-}" node "$temp_script" "$url" "$max_depth" "$page_limit" 2>&1); then
		_crawl_handle_output "$result" "$output_file"
		print_success "Crawl completed"
	else
		print_error "Crawl failed"
		printf '%s\n' "$result" >&2
		rm -rf "$temp_dir"
		return 1
	fi

	rm -rf "$temp_dir"
	return 0
}

# Search the web
search_web() {
	local query="$1"
	local limit="${2:-5}"
	local output_file="$3"

	if [[ -z "$query" ]]; then
		print_error "Search query is required"
		print_info "Usage: $0 search <query> [limit] [output.json]"
		return 1
	fi

	if ! load_api_key; then
		print_error "API key not configured"
		print_info "Run: $0 api-key YOUR_API_KEY"
		return 1
	fi

	print_header "Searching: $query"
	print_info "Using API: ${WATERCRAWL_API_URL:-}"
	print_info "Result limit: $limit"

	# Create Node.js script for searching
	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local temp_dir temp_script
	temp_dir=$(mktemp -d /tmp/watercrawl_search_XXXXXX)
	temp_script="$temp_dir/script.mjs"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -rf '${temp_dir}'"

	cat >"$temp_script" <<'SCRIPT'
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const apiKey = process.env.WATERCRAWL_API_KEY;
const apiUrl = process.env.WATERCRAWL_API_URL;
const query = process.argv[2];
const limit = parseInt(process.argv[3]) || 5;

if (!apiKey) {
    console.error('Error: WATERCRAWL_API_KEY not set');
    process.exit(1);
}

if (!query) {
    console.error('Error: Query required');
    process.exit(1);
}

const client = new WaterCrawlAPIClient(apiKey, apiUrl);

try {
    console.error(`Searching for: "${query}"...`);
    
    const results = await client.createSearchRequest(
        query,
        {
            depth: 'basic',
            search_type: 'web'
        },
        limit,
        true,  // sync
        true   // download
    );
    
    console.log(JSON.stringify(results, null, 2));
    
} catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
}
SCRIPT

	local result
	if result=$(WATERCRAWL_API_KEY="${WATERCRAWL_API_KEY:-}" WATERCRAWL_API_URL="${WATERCRAWL_API_URL:-}" node "$temp_script" "$query" "$limit" 2>&1); then
		if [[ -n "$output_file" ]]; then
			echo "$result" | grep -v "^Searching" >"$output_file"
			print_success "Results saved to: $output_file"
		else
			echo "$result" | grep -v "^Searching"
		fi
		print_success "Search completed"
	else
		print_error "Search failed"
		echo "$result" >&2
		rm -rf "$temp_dir"
		return 1
	fi

	rm -rf "$temp_dir"
	return 0
}

# Write the Node.js sitemap script to a temp file
_sitemap_write_script() {
	local temp_script="$1"
	cat >"$temp_script" <<'SCRIPT'
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const apiKey = process.env.WATERCRAWL_API_KEY;
const apiUrl = process.env.WATERCRAWL_API_URL;
const url = process.argv[2];
const format = process.argv[3] || 'json';

if (!apiKey) {
    console.error('Error: WATERCRAWL_API_KEY not set');
    process.exit(1);
}

if (!url) {
    console.error('Error: URL required');
    process.exit(1);
}

const client = new WaterCrawlAPIClient(apiKey, apiUrl);

try {
    console.error(`Creating sitemap request for: ${url}...`);
    const sitemapRequest = await client.createSitemapRequest(
        url,
        { include_subdomains: true, ignore_sitemap_xml: false, include_paths: [], exclude_paths: [] },
        true,  // sync
        true   // download
    );
    if (Array.isArray(sitemapRequest)) {
        console.log(JSON.stringify(sitemapRequest, null, 2));
    } else if (typeof sitemapRequest === 'string') {
        console.log(sitemapRequest);
    } else {
        const results = await client.getSitemapResults(sitemapRequest.uuid, format);
        if (typeof results === 'string') {
            console.log(results);
        } else {
            console.log(JSON.stringify(results, null, 2));
        }
    }
} catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
}
SCRIPT
	return 0
}

# Handle sitemap output: filter progress lines and write to file or stdout
_sitemap_handle_output() {
	local result="$1"
	local output_file="$2"
	local filtered
	filtered=$(printf '%s\n' "$result" | grep -v "^Creating sitemap")
	if [[ -n "$output_file" ]]; then
		printf '%s\n' "$filtered" >"$output_file"
		print_success "Sitemap saved to: $output_file"
	else
		printf '%s\n' "$filtered"
	fi
	return 0
}

# Generate sitemap
generate_sitemap() {
	local url="$1"
	local output_file="$2"
	local format="${3:-json}"

	if [[ -z "$url" ]]; then
		print_error "URL is required"
		print_info "Usage: $0 sitemap <url> [output.json] [format: json|markdown|graph]"
		return 1
	fi

	if ! load_api_key; then
		print_error "API key not configured"
		print_info "Run: $0 api-key YOUR_API_KEY"
		return 1
	fi

	print_header "Generating sitemap: $url"
	print_info "Using API: ${WATERCRAWL_API_URL:-}"
	print_info "Format: $format"

	# t2997: node ESM requires exact .mjs extension; mktemp -d + fixed filename.
	local temp_dir temp_script
	temp_dir=$(mktemp -d /tmp/watercrawl_sitemap_XXXXXX)
	temp_script="$temp_dir/script.mjs"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -rf '${temp_dir}'"

	_sitemap_write_script "$temp_script"

	local result
	if result=$(WATERCRAWL_API_KEY="${WATERCRAWL_API_KEY:-}" WATERCRAWL_API_URL="${WATERCRAWL_API_URL:-}" node "$temp_script" "$url" "$format" 2>&1); then
		_sitemap_handle_output "$result" "$output_file"
		print_success "Sitemap generated"
	else
		print_error "Sitemap generation failed"
		printf '%s\n' "$result" >&2
		rm -rf "$temp_dir"
		return 1
	fi

	rm -rf "$temp_dir"
	return 0
}

# Show help
show_help() {
	echo "WaterCrawl Helper Script"
	echo "Modern web crawling framework for LLM-ready data extraction"
	echo ""
	echo "SELF-HOSTED FIRST: Prioritizes local Docker deployment over cloud API."
	echo ""
	echo "Usage: $0 [command] [options]"
	echo ""
	echo "Self-Hosted Deployment (RECOMMENDED):"
	echo "  docker-setup                       - Clone repo and prepare Docker deployment"
	echo "  docker-start                       - Start WaterCrawl Docker containers"
	echo "  docker-stop                        - Stop WaterCrawl Docker containers"
	echo "  docker-logs [service]              - View Docker container logs"
	echo "  docker-admin                       - Create admin user"
	echo "  coolify-deploy                     - Instructions for Coolify deployment"
	echo ""
	echo "SDK & Configuration:"
	echo "  setup                              - Install Node.js SDK"
	echo "  status                             - Check configuration and connectivity"
	echo "  api-key <key>                      - Configure WaterCrawl API key"
	echo "  api-url <url>                      - Configure custom API URL (self-hosted)"
	echo ""
	echo "Crawling Operations:"
	echo "  scrape <url> [output.json]         - Scrape a single URL"
	echo "  crawl <url> [depth] [limit] [out]  - Crawl website with depth control"
	echo "  search <query> [limit] [out]       - Search the web"
	echo "  sitemap <url> [out] [format]       - Generate sitemap (json|markdown|graph)"
	echo ""
	echo "  help                               - $HELP_SHOW_MESSAGE"
	echo ""
	echo "Quick Start (Self-Hosted):"
	echo "  $0 docker-setup                    # Clone and configure"
	echo "  $0 docker-start                    # Start services"
	echo "  $0 docker-admin                    # Create admin user"
	echo "  # Login at http://localhost, get API key from dashboard"
	echo "  $0 api-key YOUR_API_KEY            # Configure key"
	echo "  $0 scrape https://example.com      # Test crawling"
	echo ""
	echo "Quick Start (Cloud API):"
	echo "  $0 setup                           # Install SDK"
	echo "  $0 api-url https://app.watercrawl.dev"
	echo "  $0 api-key YOUR_API_KEY            # From app.watercrawl.dev"
	echo "  $0 scrape https://example.com"
	echo ""
	echo "Resources:"
	echo "  Self-hosted docs: https://docs.watercrawl.dev/self-hosted/"
	echo "  Cloud dashboard: https://app.watercrawl.dev"
	echo "  GitHub: https://github.com/watercrawl/WaterCrawl"
	echo "  Framework docs: .agents/tools/browser/watercrawl.md"
	return 0
}

# Main function
main() {
	local command="${1:-help}"
	local param2="$2"
	local param3="$3"
	local param4="$4"
	local param5="$5"

	case "$command" in
	"docker-setup")
		docker_setup
		;;
	"docker-start")
		docker_start
		;;
	"docker-stop")
		docker_stop
		;;
	"docker-logs")
		docker_logs "$param2"
		;;
	"docker-admin")
		docker_admin
		;;
	"coolify-deploy" | "coolify")
		coolify_deploy
		;;
	"setup")
		setup_sdk
		;;
	"status")
		check_status
		;;
	"api-key")
		configure_api_key "$param2"
		;;
	"api-url")
		configure_api_url "$param2"
		;;
	"scrape")
		scrape_url "$param2" "$param3"
		;;
	"crawl")
		crawl_website "$param2" "$param3" "$param4" "$param5"
		;;
	"search")
		search_web "$param2" "$param3" "$param4"
		;;
	"sitemap")
		generate_sitemap "$param2" "$param3" "$param4"
		;;
	"help" | "-h" | "--help" | "")
		show_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		show_help
		return 1
		;;
	esac
	return 0
}

main "$@"

exit 0
