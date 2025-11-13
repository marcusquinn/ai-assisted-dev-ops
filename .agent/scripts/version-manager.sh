#!/bin/bash

# Version Manager for AI DevOps Framework
# Manages semantic versioning and automated version bumping
#
# Author: AI DevOps Framework
# Version: 1.1.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Repository root directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

# Function to get current version
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "1.0.0"
    fi
}

# Function to validate semantic version
validate_version() {
    local version="$1"
    if [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to bump version
bump_version() {
    local bump_type="$1"
    local current_version
    current_version=$(get_current_version)
    
    IFS='.' read -r major minor patch <<< "$current_version"
    
    case "$bump_type" in
        "major")
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        "minor")
            minor=$((minor + 1))
            patch=0
            ;;
        "patch")
            patch=$((patch + 1))
            ;;
        *)
            print_error "Invalid bump type. Use: major, minor, or patch"
            return 1
            ;;
    esac
    
    local new_version="$major.$minor.$patch"
    echo "$new_version" > "$VERSION_FILE"
    echo "$new_version"
}

# Function to update version in files
update_version_in_files() {
    local new_version="$1"
    
    print_info "Updating version references in files..."
    
    # Update sonar-project.properties
    if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
        sed -i '' "s/sonar\.projectVersion=.*/sonar.projectVersion=$new_version/" "$REPO_ROOT/sonar-project.properties"
        print_success "Updated sonar-project.properties"
    fi
    
    # Update setup.sh if it exists
    if [[ -f "$REPO_ROOT/setup.sh" ]]; then
        sed -i '' "s/VERSION=.*/VERSION=\"$new_version\"/" "$REPO_ROOT/setup.sh"
        print_success "Updated setup.sh"
    fi
    
    # Update script headers
    find "$REPO_ROOT/.agent/scripts" -name "*.sh" -type f -exec sed -i '' "s/# Version: .*/# Version: $new_version/" {} \;
    print_success "Updated script version headers"
}

# Function to create git tag
create_git_tag() {
    local version="$1"
    local tag_name="v$version"
    
    print_info "Creating git tag: $tag_name"
    
    cd "$REPO_ROOT" || exit 1
    
    if git tag -a "$tag_name" -m "Release $tag_name

🚀 AI DevOps Framework $tag_name

## 📋 Changes in this release:
- Repository rename and branding consistency
- Enhanced quality monitoring integration
- Improved badge display and reliability
- Comprehensive documentation updates
- Security enhancements and credential management

## 🔧 Technical improvements:
- Updated all platform integrations
- Fixed GitHub Actions workflows
- Applied code quality auto-fixes
- Enhanced version management system

## 📊 Framework status:
- 25+ service integrations ✅
- Enterprise-grade security ✅
- Comprehensive documentation ✅
- Quality monitoring ✅

Full changelog: https://github.com/marcusquinn/aidevops/compare/v1.0.0...$tag_name"; then
        print_success "Created git tag: $tag_name"
        return 0
    else
        print_error "Failed to create git tag"
        return 1
    fi
}

# Main function
main() {
    local action="$1"
    local bump_type="$2"
    
    case "$action" in
        "get")
            get_current_version
            ;;
        "bump")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 bump [major|minor|patch]"
                exit 1
            fi
            
            local current_version
            current_version=$(get_current_version)
            print_info "Current version: $current_version"
            
            local new_version
            new_version=$(bump_version "$bump_type")
            
            if [[ $? -eq 0 ]]; then
                print_success "Bumped version: $current_version → $new_version"
                update_version_in_files "$new_version"
                echo "$new_version"
            else
                exit 1
            fi
            ;;
        "tag")
            local version
            version=$(get_current_version)
            create_git_tag "$version"
            ;;
        "release")
            if [[ -z "$bump_type" ]]; then
                print_error "Bump type required. Usage: $0 release [major|minor|patch]"
                exit 1
            fi
            
            print_info "Creating release with $bump_type version bump..."
            
            local new_version
            new_version=$(bump_version "$bump_type")
            
            if [[ $? -eq 0 ]]; then
                update_version_in_files "$new_version"
                create_git_tag "$new_version"
                print_success "Release $new_version created successfully!"
            else
                exit 1
            fi
            ;;
        *)
            echo "AI DevOps Framework Version Manager"
            echo ""
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions:"
            echo "  get                    Get current version"
            echo "  bump [major|minor|patch]  Bump version"
            echo "  tag                    Create git tag for current version"
            echo "  release [major|minor|patch]  Bump version, update files, and create tag"
            echo ""
            echo "Examples:"
            echo "  $0 get"
            echo "  $0 bump minor"
            echo "  $0 release patch"
            ;;
    esac
}

main "$@"
