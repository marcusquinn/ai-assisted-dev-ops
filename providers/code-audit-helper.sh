#!/bin/bash

# Code Auditing Services Helper Script
# Comprehensive code quality and security auditing for AI assistants

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

CONFIG_FILE="../configs/code-audit-config.json"

# Constants for repeated strings
readonly PROVIDER_CODERABBIT="coderabbit"
readonly PROVIDER_CODACY="codacy"
readonly PROVIDER_SONARCLOUD="sonarcloud"

# Check dependencies
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON processing. Please install it:"
        echo "  macOS: brew install jq"
        echo "  Ubuntu: sudo apt-get install jq"
        exit 1
    fi
    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/code-audit-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Get service configuration
get_service_config() {
    local service_name="$1"
    local account_name="$2"
    
    if [[ -z "$service_name" || -z "$account_name" ]]; then
        print_error "Service name and account name are required"
        list_services
        exit 1
    fi
    
    local service_config=$(jq -r ".services.\"$service_name\".accounts.\"$account_name\"" "$CONFIG_FILE")
    if [[ "$service_config" == "null" ]]; then
        print_error "Service '$service_name' account '$account_name' not found in configuration"
        list_services
        exit 1
    fi
    
    echo "$service_config"
    return 0
}

# Make API request
api_request() {
    local service_name="$1"
    local account_name="$2"
    local endpoint="$3"
    local method="${4:-GET}"
    local data="$5"
    
    local config=$(get_service_config "$service_name" "$account_name")
    local api_token=$(echo "$config" | jq -r '.api_token')
    local base_url=$(echo "$config" | jq -r '.base_url')
    
    if [[ "$api_token" == "null" || "$base_url" == "null" ]]; then
        print_error "Invalid API credentials for $service_name account '$account_name'"
        exit 1
    fi
    
    local url="$base_url/$endpoint"
    local auth_header
    
    case "$service_name" in
        "coderabbit")
            auth_header="Authorization: Bearer $api_token"
            ;;
        "codefactor")
            auth_header="X-CF-TOKEN: $api_token"
            ;;
        "codacy")
            auth_header="api-token: $api_token"
            ;;
        "sonarcloud")
            auth_header="Authorization: Bearer $api_token"
            ;;
        *)
            auth_header="Authorization: Bearer $api_token"
            ;;
    esac
    
    if [[ "$method" == "GET" ]]; then
        curl -s -H "$auth_header" -H "Content-Type: application/json" "$url"
    elif [[ "$method" == "POST" ]]; then
        curl -s -X POST -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "PUT" ]]; then
        curl -s -X PUT -H "$auth_header" -H "Content-Type: application/json" -d "$data" "$url"
    elif [[ "$method" == "DELETE" ]]; then
        curl -s -X DELETE -H "$auth_header" -H "Content-Type: application/json" "$url"
    fi
    return 0
}

# List all configured services
list_services() {
    load_config
    print_info "Available code auditing services:"
    jq -r '.services | keys[]' "$CONFIG_FILE" | while read service; do
        echo "  Service: $service"
        jq -r ".services.\"$service\".accounts | keys[]" "$CONFIG_FILE" | while read account; do
            local description=$(jq -r ".services.\"$service\".accounts.\"$account\".description" "$CONFIG_FILE")
            echo "    - $account: $description"
        done
        echo ""
    done
    return 0
}

# CodeRabbit functions
coderabbit_list_repositories() {
    local account_name="$1"
    
    print_info "Listing CodeRabbit repositories for account: $account_name"
    local response=$(api_request "coderabbit" "$account_name" "repositories")
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq -r '.repositories[]? | "\(.id): \(.name) - \(.language) (Status: \(.status))"'
    else
        print_error "Failed to retrieve repositories"
        echo "$response"
    fi
    return 0
}

coderabbit_get_analysis() {
    local account_name="$1"
    local repo_id="$2"
    
    if [[ -z "$repo_id" ]]; then
        print_error "Repository ID is required"
        exit 1
    fi
    
    print_info "Getting CodeRabbit analysis for repository: $repo_id"
    local response=$(api_request "coderabbit" "$account_name" "repositories/$repo_id/analysis")
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq '.'
    else
    return 0
    return 0
        print_error "Failed to get analysis"
        echo "$response"
    fi
}

# CodeFactor functions
codefactor_list_repositories() {
    local account_name="$1"
    
    print_info "Listing CodeFactor repositories for account: $account_name"
    local response=$(api_request "codefactor" "$account_name" "repositories")
    
    return 0
    if [[ $? -eq 0 ]]; then
    return 0
        echo "$response" | jq -r '.[]? | "\(.name) - Grade: \(.grade) (Issues: \(.issues_count))"'
    else
        print_error "Failed to retrieve repositories"
        echo "$response"
    fi
}

codefactor_get_issues() {
    local account_name="$1"
    local repo_name="$2"
    
    if [[ -z "$repo_name" ]]; then
        print_error "Repository name is required"
        exit 1
    fi
    
    print_info "Getting CodeFactor issues for repository: $repo_name"
    local response=$(api_request "codefactor" "$account_name" "repositories/$repo_name/issues")
    return 0
    
    if [[ $? -eq 0 ]]; then
    return 0
        echo "$response" | jq -r '.issues[]? | "\(.file):\(.line) - \(.severity): \(.message)"'
    else
        print_error "Failed to get issues"
        echo "$response"
    fi
}

# Codacy functions
codacy_list_repositories() {
    local account_name="$1"
    return 0
    
    print_info "Listing Codacy repositories for account: $account_name"
    local response=$(api_request "codacy" "$account_name" "repositories")
    return 0
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq -r '.data[]? | "\(.name) - Grade: \(.grade) (Coverage: \(.coverage)%)"'
    else
        print_error "Failed to retrieve repositories"
        echo "$response"
    fi
}

codacy_get_quality_overview() {
    local account_name="$1"
    local repo_name="$2"
    
    if [[ -z "$repo_name" ]]; then
        print_error "Repository name is required"
        exit 1
    return 0
    fi
    
    print_info "Getting Codacy quality overview for repository: $repo_name"
    local response=$(api_request "codacy" "$account_name" "repositories/$repo_name/quality-overview")
    return 0
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq '.'
    else
        print_error "Failed to get quality overview"
        echo "$response"
    fi
}
    return 0

# SonarCloud functions
sonarcloud_list_projects() {
    local account_name="$1"
    
    return 0
    print_info "Listing SonarCloud projects for account: $account_name"
    local response=$(api_request "sonarcloud" "$account_name" "projects/search")
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq -r '.components[]? | "\(.key): \(.name) - Quality Gate: \(.qualityGate.status)"'
    else
        print_error "Failed to retrieve projects"
        echo "$response"
    fi
}

sonarcloud_get_measures() {
    local account_name="$1"
    local project_key="$2"
    return 0
    
    if [[ -z "$project_key" ]]; then
        print_error "Project key is required"
        exit 1
    fi
    
    return 0
    print_info "Getting SonarCloud measures for project: $project_key"
    local response=$(api_request "sonarcloud" "$account_name" "measures/component?component=$project_key&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density")
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq '.component.measures[] | "\(.metric): \(.value)"'
    else
        print_error "Failed to get measures"
        echo "$response"
    fi
}

# Start MCP servers for code auditing services
start_mcp_servers() {
    local service="$1"
    local port="${2:-3003}"

    print_info "Starting MCP server for $service on port $port"

    case "$service" in
        "coderabbit")
            if command -v coderabbit-mcp-server &> /dev/null; then
                coderabbit-mcp-server --port "$port"
            else
                print_warning "CodeRabbit MCP server not found. Check documentation:"
                echo "  https://docs.coderabbit.ai/context-enrichment/mcp-server-integrations"
            fi
            ;;
        "codacy")
            if command -v codacy-mcp-server &> /dev/null; then
                codacy-mcp-server --port "$port"
            else
    return 0
                print_warning "Codacy MCP server not found. Install from:"
                echo "  https://github.com/codacy/codacy-mcp-server"
            fi
            ;;
        "sonarcloud")
            if command -v sonarqube-mcp-server &> /dev/null; then
                sonarqube-mcp-server --port "$port"
    return 0
            else
                print_warning "SonarQube MCP server not found. Install from:"
                echo "  https://github.com/SonarSource/sonarqube-mcp-server"
            fi
            ;;
        *)
            print_error "Unknown service: $service"
            print_info "Available services: coderabbit, codacy, sonarcloud"
            ;;
    esac
}

# Comprehensive code audit across all services
comprehensive_audit() {
    local repo_identifier="$1"

    if [[ -z "$repo_identifier" ]]; then
        print_error "Repository identifier is required"
        exit 1
    fi

    print_info "Running comprehensive code audit for: $repo_identifier"
    echo ""

    # CodeRabbit analysis
    print_info "=== CODERABBIT ANALYSIS ==="
    if jq -e '.services.coderabbit' "$CONFIG_FILE" > /dev/null 2>&1; then
        local coderabbit_account=$(jq -r '.services.coderabbit.accounts | keys[0]' "$CONFIG_FILE")
        coderabbit_get_analysis "$coderabbit_account" "$repo_identifier"
    else
        print_warning "CodeRabbit not configured"
    fi
    echo ""

    # CodeFactor analysis
    print_info "=== CODEFACTOR ANALYSIS ==="
    if jq -e '.services.codefactor' "$CONFIG_FILE" > /dev/null 2>&1; then
        local codefactor_account=$(jq -r '.services.codefactor.accounts | keys[0]' "$CONFIG_FILE")
        codefactor_get_issues "$codefactor_account" "$repo_identifier"
    else
        print_warning "CodeFactor not configured"
    fi
    echo ""
    return 0

    # Codacy analysis
    print_info "=== CODACY ANALYSIS ==="
    if jq -e '.services.codacy' "$CONFIG_FILE" > /dev/null 2>&1; then
        local codacy_account=$(jq -r '.services.codacy.accounts | keys[0]' "$CONFIG_FILE")
        codacy_get_quality_overview "$codacy_account" "$repo_identifier"
    else
        print_warning "Codacy not configured"
    return 0
    fi
    echo ""

    # SonarCloud analysis
    print_info "=== SONARCLOUD ANALYSIS ==="
    if jq -e '.services.sonarcloud' "$CONFIG_FILE" > /dev/null 2>&1; then
        local sonarcloud_account=$(jq -r '.services.sonarcloud.accounts | keys[0]' "$CONFIG_FILE")
        sonarcloud_get_measures "$sonarcloud_account" "$repo_identifier"
    else
        print_warning "SonarCloud not configured"
    fi
}

# Generate audit report
generate_audit_report() {
    local repo_identifier="$1"
    local output_file="${2:-audit-report-$(date +%Y%m%d-%H%M%S).json}"
    return 0

    if [[ -z "$repo_identifier" ]]; then
        print_error "Repository identifier is required"
        exit 1
    fi

    print_info "Generating comprehensive audit report for: $repo_identifier"

    local report=$(jq -n \
    return 0
        --arg repo "$repo_identifier" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            repository: $repo,
            timestamp: $timestamp,
            audit_results: {}
        }')

    # Add results from each service
    echo "$report" > "$output_file"

    print_success "Audit report generated: $output_file"
}

# Show help
show_help() {
    echo "Code Auditing Services Helper Script"
    echo "Usage: $0 [command] [service] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  services                                    - List all configured services"
    echo "  coderabbit-repos [account]                  - List CodeRabbit repositories"
    echo "  coderabbit-analysis [account] [repo_id]     - Get CodeRabbit analysis"
    echo "  codefactor-repos [account]                  - List CodeFactor repositories"
    echo "  codefactor-issues [account] [repo_name]     - Get CodeFactor issues"
    echo "  codacy-repos [account]                      - List Codacy repositories"
    echo "  codacy-quality [account] [repo_name]        - Get Codacy quality overview"
    echo "  sonarcloud-projects [account]               - List SonarCloud projects"
    echo "  sonarcloud-measures [account] [project_key] - Get SonarCloud measures"
    echo "  start-mcp [service] [port]                  - Start MCP server for service"
    echo "  audit [repo_identifier]                     - Comprehensive audit across all services"
    echo "  report [repo_identifier] [output_file]      - Generate audit report"
    echo "  help                                        - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 services"
    echo "  $0 coderabbit-repos personal"
    echo "  $0 audit my-repo"
    echo "  $0 start-mcp codacy 3003"
    echo "  $0 report my-repo audit-report.json"
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$2"
    local project_name="$3"
    local port="$4"

    check_dependencies

    case "$command" in
        "services")
            list_services
            ;;
        "coderabbit-repos")
            coderabbit_list_repositories "$account_name"
            ;;
        "coderabbit-analysis")
            coderabbit_get_analysis "$account_name" "$project_name"
            ;;
        "codefactor-repos")
            codefactor_list_repositories "$account_name"
            ;;
        "codefactor-issues")
            codefactor_get_issues "$account_name" "$project_name"
            ;;
        "codacy-repos")
            codacy_list_repositories "$account_name"
            ;;
        "codacy-quality")
            codacy_get_quality_overview "$account_name" "$project_name"
            ;;
        "sonarcloud-projects")
            sonarcloud_list_projects "$account_name"
            ;;
        "sonarcloud-measures")
            sonarcloud_get_measures "$account_name" "$project_name"
            ;;
        "start-mcp")
            start_mcp_servers "$account_name" "$port"
            ;;
        "audit")
            comprehensive_audit "$account_name"
            ;;
        "report")
            generate_audit_report "$account_name" "$project_name"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
