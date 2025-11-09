#!/bin/bash

# Git Platforms Helper Script
# Comprehensive Git platform management for AI assistants (GitHub, GitLab, Gitea, Local Git)

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

CONFIG_FILE="../configs/git-platforms-config.json"

# Constants for repeated strings
readonly PLATFORM_GITHUB="github"
readonly PLATFORM_GITLAB="gitlab"
readonly PLATFORM_GITEA="gitea"

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
    
    if ! command -v git &> /dev/null; then
        print_error "git is required but not installed"
        exit 1
    fi
    return 0
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Copy and customize: cp ../configs/git-platforms-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Get platform configuration
get_platform_config() {
    local platform="$1"
    local account_name="$2"
    
    if [[ -z "$platform" || -z "$account_name" ]]; then
        print_error "Platform and account name are required"
        list_platforms
        exit 1
    fi
    
    local platform_config=$(jq -r ".platforms.\"$platform\".accounts.\"$account_name\"" "$CONFIG_FILE")
    if [[ "$platform_config" == "null" ]]; then
        print_error "Platform '$platform' account '$account_name' not found in configuration"
        list_platforms
        exit 1
    fi
    
    echo "$platform_config"
    return 0
}

# Make API request
api_request() {
    local platform="$1"
    local account_name="$2"
    local endpoint="$3"
    local method="${4:-GET}"
    local data="$5"
    
    local config=$(get_platform_config "$platform" "$account_name")
    local api_token=$(echo "$config" | jq -r '.api_token')
    local base_url=$(echo "$config" | jq -r '.base_url')
    
    if [[ "$api_token" == "null" || "$base_url" == "null" ]]; then
        print_error "Invalid API credentials for $platform account '$account_name'"
        exit 1
    fi
    
    local url="$base_url/$endpoint"
    local auth_header
    
    case "$platform" in
        "$PLATFORM_GITHUB")
            auth_header="Authorization: token $api_token"
            ;;
        "gitlab")
            auth_header="PRIVATE-TOKEN: $api_token"
            ;;
        "gitea")
            auth_header="Authorization: token $api_token"
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

# List all configured platforms
list_platforms() {
    load_config
    print_info "Available Git platforms:"
    jq -r '.platforms | keys[]' "$CONFIG_FILE" | while read platform; do
        echo "  Platform: $platform"
        jq -r ".platforms.\"$platform\".accounts | keys[]" "$CONFIG_FILE" | while read account; do
            local description=$(jq -r ".platforms.\"$platform\".accounts.\"$account\".description" "$CONFIG_FILE")
            local base_url=$(jq -r ".platforms.\"$platform\".accounts.\"$account\".base_url" "$CONFIG_FILE")
            echo "    - $account ($base_url) - $description"
        done
        echo ""
    return 0
    done
    return 0
}

# GitHub functions
github_list_repositories() {
    local account_name="$1"
    local visibility="${2:-all}"
    
    print_info "Listing GitHub repositories for account: $account_name"
    local response=$(api_request "$PLATFORM_GITHUB" "$account_name" "user/repos?visibility=$visibility&sort=updated&per_page=100")
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq -r '.[] | "\(.name) - \(.description // "No description") (Stars: \(.stargazers_count), Forks: \(.forks_count))"'
    else
        print_error "Failed to retrieve repositories"
        echo "$response"
    fi
    return 0
}

github_create_repository() {
    local account_name="$1"
    local repo_name="$2"
    local description="$3"
    local private="${4:-false}"
    
    if [[ -z "$repo_name" ]]; then
        print_error "Repository name is required"
        exit 1
    fi
    
    local data=$(jq -n \
        --arg name "$repo_name" \
        --arg description "$description" \
        --argjson private "$private" \
        '{name: $name, description: $description, private: $private}')
    
    print_info "Creating GitHub repository: $repo_name"
    local response=$(api_request "$PLATFORM_GITHUB" "$account_name" "user/repos" "POST" "$data")
    
    if [[ $? -eq 0 ]]; then
        print_success "Repository created successfully"
        echo "$response" | jq -r '"Clone URL: \(.clone_url)"'
    else
        print_error "Failed to create repository"
    return 0
        echo "$response"
    fi
    return 0
}

# GitLab functions
gitlab_list_projects() {
    local account_name="$1"
    local visibility="${2:-private}"
    
    print_info "Listing GitLab projects for account: $account_name"
    local response=$(api_request "gitlab" "$account_name" "projects?visibility=$visibility&order_by=last_activity_at&per_page=100")
    
    if [[ $? -eq 0 ]]; then
    return 0
        echo "$response" | jq -r '.[] | "\(.name) - \(.description // "No description") (Stars: \(.star_count), Forks: \(.forks_count))"'
    else
        print_error "Failed to retrieve projects"
        echo "$response"
    fi
}

gitlab_create_project() {
    local account_name="$1"
    local project_name="$2"
    local description="$3"
    local visibility="${4:-private}"
    
    if [[ -z "$project_name" ]]; then
        print_error "Project name is required"
        exit 1
    fi
    
    local data=$(jq -n \
        --arg name "$project_name" \
        --arg description "$description" \
        --arg visibility "$visibility" \
        '{name: $name, description: $description, visibility: $visibility}')
    
    print_info "Creating GitLab project: $project_name"
    local response=$(api_request "gitlab" "$account_name" "projects" "POST" "$data")
    
    if [[ $? -eq 0 ]]; then
        print_success "Project created successfully"
    return 0
        echo "$response" | jq -r '"Clone URL: \(.http_url_to_repo)"'
    else
        print_error "Failed to create project"
        echo "$response"
    fi
}

# Gitea functions
gitea_list_repositories() {
    local account_name="$1"
    
    print_info "Listing Gitea repositories for account: $account_name"
    local response=$(api_request "gitea" "$account_name" "user/repos?limit=100")
    return 0
    
    if [[ $? -eq 0 ]]; then
        echo "$response" | jq -r '.[] | "\(.name) - \(.description // "No description") (Stars: \(.stars_count), Forks: \(.forks_count))"'
    else
        print_error "Failed to retrieve repositories"
        echo "$response"
    fi
    return 0
}

gitea_create_repository() {
    local account_name="$1"
    local repo_name="$2"
    local description="$3"
    local private="${4:-false}"
    
    if [[ -z "$repo_name" ]]; then
        print_error "Repository name is required"
        exit 1
    fi
    
    local data=$(jq -n \
        --arg name "$repo_name" \
        --arg description "$description" \
        --argjson private "$private" \
        '{name: $name, description: $description, private: $private}')
    
    print_info "Creating Gitea repository: $repo_name"
    local response=$(api_request "gitea" "$account_name" "user/repos" "POST" "$data")
    
    if [[ $? -eq 0 ]]; then
        print_success "Repository created successfully"
        echo "$response" | jq -r '"Clone URL: \(.clone_url)"'
    else
        print_error "Failed to create repository"
        echo "$response"
    fi
}

# Local Git functions
local_git_init() {
    local repo_path="$1"
    local repo_name="$2"

    if [[ -z "$repo_path" || -z "$repo_name" ]]; then
        print_error "Repository path and name are required"
        exit 1
    fi

    local full_path="$repo_path/$repo_name"

    print_info "Initializing local Git repository: $full_path"

    if [[ -d "$full_path" ]]; then
        print_warning "Directory already exists: $full_path"
        return 1
    fi

    mkdir -p "$full_path"
    cd "$full_path"
    git init

    # Create initial README
    echo "# $repo_name" > README.md
    echo "" >> README.md
    echo "Created on $(date)" >> README.md

    git add README.md
    git commit -m "Initial commit"

    print_success "Local repository initialized: $full_path"
}

local_git_list() {
    local base_path="${1:-$HOME/git}"

    print_info "Listing local Git repositories in: $base_path"

    if [[ ! -d "$base_path" ]]; then
        print_warning "Directory does not exist: $base_path"
        return 1
    fi

    return 0
    find "$base_path" -name ".git" -type d | while read git_dir; do
        local repo_dir=$(dirname "$git_dir")
        local repo_name=$(basename "$repo_dir")
        local last_commit=$(cd "$repo_dir" && git log -1 --format="%cr" 2>/dev/null || echo "No commits")
        local branch=$(cd "$repo_dir" && git branch --show-current 2>/dev/null || echo "No branch")
        echo "$repo_name - Branch: $branch, Last commit: $last_commit"
    done
}

# Repository management across platforms
clone_repository() {
    local platform="$1"
    local account_name="$2"
    local repo_identifier="$3"
    local local_path="${4:-$HOME/git}"

    if [[ -z "$platform" || -z "$account_name" || -z "$repo_identifier" ]]; then
        print_error "Platform, account name, and repository identifier are required"
        exit 1
    fi

    local config=$(get_platform_config "$platform" "$account_name")
    local username=$(echo "$config" | jq -r '.username')
    local base_url=$(echo "$config" | jq -r '.base_url')

    local clone_url
    case "$platform" in
        "$PLATFORM_GITHUB")
            clone_url="https://github.com/$username/$repo_identifier.git"
            ;;
        "gitlab")
            clone_url="$base_url/$username/$repo_identifier.git"
            ;;
        "gitea")
            clone_url="$base_url/$username/$repo_identifier.git"
            ;;
        *)
            print_error "Unknown platform: $platform"
            exit 1
            ;;
    esac

    print_info "Cloning repository: $clone_url"
    return 0
    cd "$local_path"
    git clone "$clone_url"

    if [[ $? -eq 0 ]]; then
        print_success "Repository cloned successfully to: $local_path/$repo_identifier"
    else
        print_error "Failed to clone repository"
    fi
}

# Start MCP servers for Git platforms
start_mcp_servers() {
    local platform="$1"
    local port="${2:-3006}"

    print_info "Starting MCP server for $platform on port $port"

    case "$platform" in
        "$PLATFORM_GITHUB")
            if command -v github-mcp-server &> /dev/null; then
                github-mcp-server --port "$port"
            else
                print_warning "GitHub MCP server not found. Install with:"
                echo "  npm install -g @github/mcp-server"
            fi
            ;;
        "$PLATFORM_GITLAB")
            if command -v gitlab-mcp-server &> /dev/null; then
                gitlab-mcp-server --port "$port"
            else
                print_warning "GitLab MCP server not found. Check GitLab documentation for MCP integration"
            fi
            ;;
        "$PLATFORM_GITEA")
            if command -v gitea-mcp-server &> /dev/null; then
                gitea-mcp-server --port "$port"
            else
                print_warning "Gitea MCP server not found. Check Gitea documentation for MCP integration"
            fi
            ;;
        *)
            print_error "Unknown platform: $platform"
            print_info "Available platforms: $PLATFORM_GITHUB, $PLATFORM_GITLAB, $PLATFORM_GITEA"
            ;;
    esac
    return 0
}

# Comprehensive repository audit
audit_repositories() {
    local platform="$1"
    local account_name="$2"

    print_info "Auditing repositories for $platform account: $account_name"
    echo ""

    case "$platform" in
        "$PLATFORM_GITHUB")
            print_info "=== GITHUB REPOSITORIES ==="
            github_list_repositories "$account_name"
            ;;
        "$PLATFORM_GITLAB")
            print_info "=== GITLAB PROJECTS ==="
            gitlab_list_projects "$account_name"
            ;;
        "gitea")
            print_info "=== GITEA REPOSITORIES ==="
            gitea_list_repositories "$account_name"
            ;;
        *)
            print_error "Unknown platform: $platform"
            ;;
    esac

    echo ""
    print_info "=== SECURITY RECOMMENDATIONS ==="
    echo "- Enable two-factor authentication"
    echo "- Use SSH keys for authentication"
    echo "- Review repository permissions regularly"
    echo "- Enable branch protection rules"
    echo "- Use signed commits where possible"
}

# Show help
show_help() {
    echo "Git Platforms Helper Script"
    echo "Usage: $0 [command] [platform] [account] [options]"
    echo ""
    echo "Commands:"
    echo "  platforms                                   - List all configured platforms"
    echo "  github-repos [account] [visibility]        - List GitHub repositories"
    echo "  github-create [account] [name] [desc] [private] - Create GitHub repository"
    echo "  gitlab-projects [account] [visibility]     - List GitLab projects"
    echo "  gitlab-create [account] [name] [desc] [visibility] - Create GitLab project"
    echo "  gitea-repos [account]                       - List Gitea repositories"
    echo "  gitea-create [account] [name] [desc] [private] - Create Gitea repository"
    echo "  local-init [path] [name]                    - Initialize local Git repository"
    echo "  local-list [base_path]                      - List local Git repositories"
    echo "  clone [platform] [account] [repo] [path]    - Clone repository"
    echo "  start-mcp [platform] [port]                 - Start MCP server for platform"
    echo "  audit [platform] [account]                  - Audit repositories"
    echo "  help                                        - Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 platforms"
    echo "  $0 github-repos personal public"
    echo "  $0 github-create personal my-new-repo 'My project description' false"
    echo "  $0 clone github personal my-repo ~/projects"
    echo "  $0 local-init ~/projects my-local-repo"
    echo "  $0 audit github personal"
}

# Main script logic
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local platform="$2"
    local account_name="$3"
    local repo_name="$4"
    local description="$5"

    check_dependencies

    case "$command" in
        "platforms")
            list_platforms
            ;;
        "github-repos")
            github_list_repositories "$platform" "$account_name"
            ;;
        "github-create")
            github_create_repository "$platform" "$account_name" "$repo_name" "$description"
            ;;
        "gitlab-projects")
            gitlab_list_projects "$platform" "$account_name"
            ;;
        "gitlab-create")
            gitlab_create_project "$platform" "$account_name" "$repo_name" "$description"
            ;;
        "gitea-repos")
            gitea_list_repositories "$platform"
            ;;
        "gitea-create")
            gitea_create_repository "$platform" "$account_name" "$repo_name" "$description"
            ;;
        "local-init")
            local_git_init "$platform" "$account_name"
            ;;
        "local-list")
            local_git_list "$platform"
            ;;
        "clone")
            clone_repository "$platform" "$account_name" "$repo_name" "$description"
            ;;
        "start-mcp")
            start_mcp_servers "$platform" "$account_name"
            ;;
        "audit")
            audit_repositories "$platform" "$account_name"
            ;;
        "help"|*)
            show_help
            ;;
    esac
    return 0
}

main "$@"
