#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2155
# =============================================================================
# OpenCode CLI Testing Helper
# =============================================================================
# Quick testing of OpenCode configuration changes without TUI restart.
# Useful for testing new MCPs, agent permissions, and slash commands.
#
# Usage:
#   opencode-test-helper.sh test-mcp <mcp-name> <agent>
#   opencode-test-helper.sh test-agent <agent>
#   opencode-test-helper.sh list-tools <agent>
#   opencode-test-helper.sh serve [port]
#   opencode-test-helper.sh attach <message> [agent] [port]
#   opencode-test-helper.sh run <message> [--agent <agent>]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

show_help() {
    cat << 'EOF'
OpenCode CLI Testing Helper

Test OpenCode configuration changes without restarting the TUI.

Commands:
  test-mcp <mcp-name> [agent]   Test if MCP is accessible by agent
  test-agent <agent>            Test agent tool permissions
  list-tools [agent]            List tools available to agent
  serve [port]                  Start persistent server (default: 4096)
  attach <message> [agent]      Run against persistent server
  run <message> [--agent name]  Run single command (passthrough to opencode)
  
Examples:
  opencode-test-helper.sh test-mcp dataforseo SEO
  opencode-test-helper.sh test-mcp serper SEO
  opencode-test-helper.sh test-agent Plan+
  opencode-test-helper.sh list-tools Build+
  opencode-test-helper.sh serve 4096
  opencode-test-helper.sh attach "quick test" SEO

Workflow for testing new MCPs:
  1. Edit ~/.config/opencode/opencode.json
  2. Run: opencode-test-helper.sh test-mcp <mcp-name> <agent>
  3. If working, restart TUI
  4. If failing, check output and iterate
EOF
    return 0
}

# Check if opencode is installed
check_opencode() {
    if ! command -v opencode &> /dev/null; then
        print_error "OpenCode CLI not found. Install from https://opencode.ai"
        exit 1
    fi
    return 0
}

# Test if MCP is accessible by agent
test_mcp() {
    local mcp_name="$1"
    local agent="${2:-Build+}"
    
    print_info "Testing MCP '$mcp_name' with agent '$agent'..."
    echo ""
    
    local result
    result=$(opencode run "Invoke the '${agent}' subagent. In that subagent, use aidevops_mcp to connect '${mcp_name}', then confirm whether '${mcp_name}_*' tools become available on the following step. Disconnect when finished. If activation or delegation is unavailable, say 'No ${mcp_name} tools available' and include the exact diagnostic." 2>&1) || true
    
    echo "$result"
    echo ""
    
    if echo "$result" | grep -qi "no.*tools\|not available\|error\|failed"; then
        print_warning "MCP '$mcp_name' may not be accessible to agent '$agent'"
        print_info "Check ~/.config/opencode/opencode.json for:"
        print_info "  1. MCP server is defined in 'mcp' section"
        print_info "  2. The '$agent' activation agent has aidevops_mcp and '${mcp_name}_*' permissions"
        return 1
    else
        print_success "MCP '$mcp_name' appears accessible to agent '$agent'"
        return 0
    fi
}

# Test agent permissions
test_agent() {
    local agent="$1"
    
    print_info "Testing agent '$agent' permissions..."
    echo ""
    
    print_info "Testing read access..."
    opencode run "Read the first 3 lines of ~/.aidevops/agents/AGENTS.md and confirm you can read files." --agent "$agent" 2>&1 || true
    echo ""
    
    print_info "Testing write access (should fail for read-only agents like Plan+)..."
    local write_result
    write_result=$(opencode run "Try to create a file at /tmp/opencode-test-$$.txt with content 'test'. Report if you succeeded or were denied." --agent "$agent" 2>&1) || true
    echo "$write_result"
    
    # Cleanup
    rm -f "/tmp/opencode-test-$$.txt" 2>/dev/null || true
    
    echo ""
    if echo "$write_result" | grep -qi "denied\|cannot\|not allowed\|permission"; then
        print_info "Agent '$agent' is read-only (write denied)"
    else
        print_info "Agent '$agent' has write access"
    fi
    
    return 0
}

# List tools available to agent
list_tools() {
    local agent="${1:-Build+}"
    
    print_info "Listing tools for agent '$agent'..."
    echo ""
    
    opencode run "List ALL tools you have access to. Group them by: 1) Built-in tools (read, write, edit, bash, etc.) 2) MCP tools (grouped by MCP name). Be comprehensive and format as a clear list." --agent "$agent" 2>&1 || true
    
    return 0
}

# Start persistent server
start_serve() {
    local port="${1:-4096}"
    
    print_info "Starting OpenCode server on port $port..."
    print_info "Use 'opencode run --attach http://localhost:$port \"message\" --agent AgentName' to test"
    print_info "Or use: $0 attach \"message\" AgentName"
    print_warning "Press Ctrl+C to stop"
    echo ""
    
    opencode serve --port "$port"
    return 0
}

# Run against persistent server
run_attach() {
    local message="$1"
    local agent="${2:-Build+}"
    local port="${3:-4096}"
    
    print_info "Running against server on port $port with agent '$agent'..."
    opencode run --attach "http://localhost:$port" "$message" --agent "$agent"
    return 0
}

# Passthrough to opencode run
run_passthrough() {
    opencode run "$@"
    return 0
}

# Main
main() {
    check_opencode
    
    local command="${1:-help}"
    
    case "$command" in
        test-mcp)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 test-mcp <mcp-name> [agent]"; exit 1; }
            test_mcp "$2" "${3:-Build+}"
            ;;
        test-agent)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 test-agent <agent>"; exit 1; }
            test_agent "$2"
            ;;
        list-tools)
            list_tools "${2:-Build+}"
            ;;
        serve)
            start_serve "${2:-4096}"
            ;;
        attach)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 attach <message> [agent] [port]"; exit 1; }
            run_attach "$2" "${3:-Build+}" "${4:-4096}"
            ;;
        run)
            shift
            run_passthrough "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
    
    return 0
}

main "$@"
