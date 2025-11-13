#!/bin/bash

# Linter Manager - CodeFactor-Inspired Multi-Language Linter Installation
# Based on CodeFactor's comprehensive linter collection
# 
# Author: AI DevOps Framework
# Version: 1.0.0
# Reference: https://docs.codefactor.io/bootcamp/analysis-tools/

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_header() {
    echo -e "${PURPLE}🔧 $1${NC}"
    echo "=========================================="
}

# Detect project languages and frameworks
detect_project_languages() {
    local languages=()
    
    # Python
    if [[ -f "requirements.txt" || -f "setup.py" || -f "pyproject.toml" || -f "Pipfile" ]]; then
        languages+=("python")
    fi
    
    # JavaScript/TypeScript/Node.js
    if [[ -f "package.json" || -f "tsconfig.json" ]]; then
        languages+=("javascript")
    fi
    
    # CSS/SCSS/Less
    if find . -name "*.css" -o -name "*.scss" -o -name "*.less" -o -name "*.sass" | head -1 | grep -q .; then
        languages+=("css")
    fi
    
    # Shell scripts
    if find . -name "*.sh" -o -name "*.bash" -o -name "*.zsh" | head -1 | grep -q .; then
        languages+=("shell")
    fi
    
    # Docker
    if [[ -f "Dockerfile" ]] || find . -name "Dockerfile*" | head -1 | grep -q .; then
        languages+=("docker")
    fi
    
    # YAML
    if find . -name "*.yml" -o -name "*.yaml" | head -1 | grep -q .; then
        languages+=("yaml")
    fi
    
    # Go
    if [[ -f "go.mod" || -f "go.sum" ]]; then
        languages+=("go")
    fi
    
    # PHP
    if [[ -f "composer.json" ]] || find . -name "*.php" | head -1 | grep -q .; then
        languages+=("php")
    fi
    
    # Ruby
    if [[ -f "Gemfile" || -f "Rakefile" ]] || find . -name "*.rb" | head -1 | grep -q .; then
        languages+=("ruby")
    fi
    
    # Java
    if [[ -f "pom.xml" || -f "build.gradle" ]] || find . -name "*.java" | head -1 | grep -q .; then
        languages+=("java")
    fi
    
    # C#
    if find . -name "*.cs" -o -name "*.csproj" -o -name "*.sln" | head -1 | grep -q .; then
        languages+=("csharp")
    fi
    
    # Swift
    if find . -name "*.swift" -o -name "Package.swift" | head -1 | grep -q .; then
        languages+=("swift")
    fi
    
    # Kotlin
    if find . -name "*.kt" -o -name "*.kts" | head -1 | grep -q .; then
        languages+=("kotlin")
    fi
    
    # Dart/Flutter
    if [[ -f "pubspec.yaml" ]] || find . -name "*.dart" | head -1 | grep -q .; then
        languages+=("dart")
    fi
    
    # R
    if find . -name "*.R" -o -name "*.r" -o -name "DESCRIPTION" | head -1 | grep -q .; then
        languages+=("r")
    fi
    
    # C/C++
    if find . -name "*.c" -o -name "*.cpp" -o -name "*.cc" -o -name "*.h" -o -name "*.hpp" | head -1 | grep -q .; then
        languages+=("cpp")
    fi
    
    # Haskell
    if find . -name "*.hs" -o -name "*.lhs" -o -name "*.cabal" | head -1 | grep -q .; then
        languages+=("haskell")
    fi
    
    # Groovy
    if find . -name "*.groovy" -o -name "*.gradle" | head -1 | grep -q .; then
        languages+=("groovy")
    fi
    
    # PowerShell
    if find . -name "*.ps1" -o -name "*.psm1" -o -name "*.psd1" | head -1 | grep -q .; then
        languages+=("powershell")
    fi
    
    # Security scanning (always relevant)
    languages+=("security")
    
    printf '%s\n' "${languages[@]}"
}

# Install Python linters (CodeFactor: pycodestyle, Pylint, Bandit, Ruff)
install_python_linters() {
    print_header "Installing Python Linters (CodeFactor-inspired)"
    
    local success=0
    local total=0
    
    # pycodestyle (PEP 8 style guide checker)
    print_info "Installing pycodestyle..."
    if pip install pycodestyle &>/dev/null; then
        print_success "pycodestyle installed"
        ((success++))
    else
        print_error "Failed to install pycodestyle"
    fi
    ((total++))
    
    # Pylint (comprehensive Python linter)
    print_info "Installing Pylint..."
    if pip install pylint &>/dev/null; then
        print_success "Pylint installed"
        ((success++))
    else
        print_error "Failed to install Pylint"
    fi
    ((total++))
    
    # Bandit (security linter)
    print_info "Installing Bandit..."
    if pip install bandit &>/dev/null; then
        print_success "Bandit installed"
        ((success++))
    else
        print_error "Failed to install Bandit"
    fi
    ((total++))
    
    # Ruff (fast Python linter)
    print_info "Installing Ruff..."
    if pip install ruff &>/dev/null; then
        print_success "Ruff installed"
        ((success++))
    else
        print_error "Failed to install Ruff"
    fi
    ((total++))
    
    print_info "Python linters: $success/$total installed successfully"
    return $((total - success))
}

# Install JavaScript/TypeScript linters (CodeFactor: Oxlint, ESLint)
install_javascript_linters() {
    print_header "Installing JavaScript/TypeScript Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # ESLint (JavaScript/TypeScript linter)
    print_info "Installing ESLint..."
    if npm install -g eslint &>/dev/null; then
        print_success "ESLint installed"
        ((success++))
    else
        print_error "Failed to install ESLint"
    fi
    ((total++))

    # TypeScript ESLint parser and plugin
    print_info "Installing TypeScript ESLint support..."
    if npm install -g @typescript-eslint/parser @typescript-eslint/eslint-plugin &>/dev/null; then
        print_success "TypeScript ESLint support installed"
        ((success++))
    else
        print_error "Failed to install TypeScript ESLint support"
    fi
    ((total++))

    print_info "JavaScript/TypeScript linters: $success/$total installed successfully"
    return $((total - success))
}

# Install CSS linters (CodeFactor: Stylelint)
install_css_linters() {
    print_header "Installing CSS/SCSS/Less Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # Stylelint (CSS/SCSS/Less linter)
    print_info "Installing Stylelint..."
    if npm install -g stylelint stylelint-config-standard &>/dev/null; then
        print_success "Stylelint installed"
        ((success++))
    else
        print_error "Failed to install Stylelint"
    fi
    ((total++))

    print_info "CSS linters: $success/$total installed successfully"
    return $((total - success))
}

# Install Shell linters (CodeFactor: ShellCheck)
install_shell_linters() {
    print_header "Installing Shell Script Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # ShellCheck (shell script linter)
    print_info "Installing ShellCheck..."
    if command -v shellcheck &>/dev/null; then
        print_success "ShellCheck already installed"
        ((success++))
    elif brew install shellcheck &>/dev/null; then
        print_success "ShellCheck installed via Homebrew"
        ((success++))
    elif apt-get install -y shellcheck &>/dev/null; then
        print_success "ShellCheck installed via apt"
        ((success++))
    else
        print_error "Failed to install ShellCheck"
    fi
    ((total++))

    print_info "Shell linters: $success/$total installed successfully"
    return $((total - success))
}

# Install Docker linters (CodeFactor: Hadolint)
install_docker_linters() {
    print_header "Installing Docker Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # Hadolint (Dockerfile linter)
    print_info "Installing Hadolint..."
    if command -v hadolint &>/dev/null; then
        print_success "Hadolint already installed"
        ((success++))
    elif brew install hadolint &>/dev/null; then
        print_success "Hadolint installed via Homebrew"
        ((success++))
    else
        print_error "Failed to install Hadolint"
    fi
    ((total++))

    print_info "Docker linters: $success/$total installed successfully"
    return $((total - success))
}

# Install YAML linters (CodeFactor: Yamllint)
install_yaml_linters() {
    print_header "Installing YAML Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # yamllint (YAML linter)
    print_info "Installing yamllint..."
    if pip install yamllint &>/dev/null; then
        print_success "yamllint installed"
        ((success++))
    else
        print_error "Failed to install yamllint"
    fi
    ((total++))

    print_info "YAML linters: $success/$total installed successfully"
    return $((total - success))
}

# Install Security linters (CodeFactor: Trivy)
install_security_linters() {
    print_header "Installing Security Linters (CodeFactor-inspired)"

    local success=0
    local total=0

    # Trivy (vulnerability scanner)
    print_info "Installing Trivy..."
    if command -v trivy &>/dev/null; then
        print_success "Trivy already installed"
        ((success++))
    elif brew install trivy &>/dev/null; then
        print_success "Trivy installed via Homebrew"
        ((success++))
    else
        print_error "Failed to install Trivy"
    fi
    ((total++))

    print_info "Security linters: $success/$total installed successfully"
    return $((total - success))
}

# Install linters for detected languages
install_detected_linters() {
    print_header "Auto-Installing Linters for Detected Languages"

    local languages_output
    languages_output=$(detect_project_languages)

    if [[ -z "$languages_output" ]]; then
        print_warning "No supported languages detected in current directory"
        return 1
    fi

    # Convert output to array
    local -a languages
    mapfile -t languages <<< "$languages_output"

    print_info "Detected languages: ${languages[*]}"
    echo ""

    local total_failures=0

    for lang in "${languages[@]}"; do
        case "$lang" in
            "python")
                install_python_linters
                ((total_failures += $?))
                ;;
            "javascript")
                install_javascript_linters
                ((total_failures += $?))
                ;;
            "css")
                install_css_linters
                ((total_failures += $?))
                ;;
            "shell")
                install_shell_linters
                ((total_failures += $?))
                ;;
            "docker")
                install_docker_linters
                ((total_failures += $?))
                ;;
            "yaml")
                install_yaml_linters
                ((total_failures += $?))
                ;;
            "security")
                install_security_linters
                ((total_failures += $?))
                ;;
        esac
        echo ""
    done

    if [[ $total_failures -eq 0 ]]; then
        print_success "All linters installed successfully!"
    else
        print_warning "Some linters failed to install ($total_failures failures)"
    fi

    return $total_failures
}

# Install all supported linters
install_all_linters() {
    print_header "Installing All Supported Linters (CodeFactor Collection)"

    local total_failures=0

    install_python_linters
    ((total_failures += $?))
    echo ""

    install_javascript_linters
    ((total_failures += $?))
    echo ""

    install_css_linters
    ((total_failures += $?))
    echo ""

    install_shell_linters
    ((total_failures += $?))
    echo ""

    install_docker_linters
    ((total_failures += $?))
    echo ""

    install_yaml_linters
    ((total_failures += $?))
    echo ""

    install_security_linters
    ((total_failures += $?))
    echo ""

    if [[ $total_failures -eq 0 ]]; then
        print_success "All linters installed successfully!"
    else
        print_warning "Some linters failed to install ($total_failures failures)"
    fi

    return $total_failures
}

# Show help
show_help() {
    echo "Linter Manager - CodeFactor-Inspired Multi-Language Linter Installation"
    echo ""
    echo "Usage: $0 <command> [language]"
    echo ""
    echo "Commands:"
    echo "  detect               - Detect languages in current project"
    echo "  install-detected     - Install linters for detected languages"
    echo "  install-all          - Install all supported linters"
    echo "  install <language>   - Install linters for specific language"
    echo "  help                 - Show this help message"
    echo ""
    echo "Supported Languages:"
    echo "  python               - pycodestyle, Pylint, Bandit, Ruff"
    echo "  javascript           - ESLint, TypeScript ESLint"
    echo "  css                  - Stylelint"
    echo "  shell                - ShellCheck"
    echo "  docker               - Hadolint"
    echo "  yaml                 - yamllint"
    echo "  security             - Trivy"
    echo ""
    echo "Examples:"
    echo "  $0 detect"
    echo "  $0 install-detected"
    echo "  $0 install-all"
    echo "  $0 install python"
    echo "  $0 install javascript"
    echo ""
    echo "Based on CodeFactor's comprehensive linter collection:"
    echo "https://docs.codefactor.io/bootcamp/analysis-tools/"
}

# Main execution
main() {
    local command="$1"
    local language="$2"

    case "$command" in
        "detect")
            print_header "Detecting Project Languages"
            local languages_output
            languages_output=$(detect_project_languages)
            if [[ -n "$languages_output" ]]; then
                print_info "Detected languages: $languages_output"
            else
                print_warning "No supported languages detected"
            fi
            ;;
        "install-detected")
            install_detected_linters
            ;;
        "install-all")
            install_all_linters
            ;;
        "install")
            if [[ -z "$language" ]]; then
                print_error "Language required for install command"
                echo ""
                show_help
                return 1
            fi

            case "$language" in
                "python")
                    install_python_linters
                    ;;
                "javascript")
                    install_javascript_linters
                    ;;
                "css")
                    install_css_linters
                    ;;
                "shell")
                    install_shell_linters
                    ;;
                "docker")
                    install_docker_linters
                    ;;
                "yaml")
                    install_yaml_linters
                    ;;
                "security")
                    install_security_linters
                    ;;
                *)
                    print_error "Unsupported language: $language"
                    echo ""
                    show_help
                    return 1
                    ;;
            esac
            ;;
        "help"|"--help"|"-h"|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
}

main "$@"
