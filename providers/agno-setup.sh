#!/bin/bash

# Agno + Agent-UI Setup Script for AI DevOps Framework
# Sets up local Agno AgentOS and Agent-UI for AI assistant capabilities
#
# Author: AI DevOps Framework
# Version: 1.2.0

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

# Configuration
AGNO_DIR="$HOME/.aidevops/agno"
AGENT_UI_DIR="$HOME/.aidevops/agent-ui"
AGNO_PORT="${AGNO_PORT:-8000}"
AGENT_UI_PORT="${AGENT_UI_PORT:-3000}"

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is required but not installed"
        return 1
    fi
    
    local python_version=$(python3 --version | cut -d' ' -f2 | cut -d'.' -f1-2)
    if [[ $(echo "$python_version >= 3.8" | bc -l) -eq 0 ]]; then
        print_error "Python 3.8+ is required, found $python_version"
        return 1
    fi
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required but not installed"
        print_info "Install Node.js from: https://nodejs.org/"
        return 1
    fi
    
    local node_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_version -lt 18 ]]; then
        print_error "Node.js 18+ is required, found v$node_version"
        return 1
    fi
    
    # Check npm
    if ! command -v npm &> /dev/null; then
        print_error "npm is required but not installed"
        return 1
    fi
    
    print_success "All prerequisites met"
    return 0
}

# Function to setup Agno AgentOS
setup_agno() {
    print_info "Setting up Agno AgentOS..."
    
    # Create directory
    mkdir -p "$AGNO_DIR"
    cd "$AGNO_DIR"
    
    # Create virtual environment
    if [[ ! -d "venv" ]]; then
        print_info "Creating Python virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate virtual environment
    source venv/bin/activate
    
    # Install Agno with browser automation
    print_info "Installing Agno with browser automation..."
    pip install --upgrade pip
    pip install "agno[all]"
    pip install playwright selenium beautifulsoup4 requests-html

    # Install Playwright browsers
    print_info "Installing Playwright browsers..."
    playwright install
    
    # Create basic AgentOS configuration
    if [[ ! -f "agent_os.py" ]]; then
        print_info "Creating AgentOS configuration..."
        cat > agent_os.py << 'EOF'
#!/usr/bin/env python3
"""
AI DevOps Framework - Agno AgentOS Configuration
Provides local AI agent capabilities for the AI DevOps framework
"""

from agno import Agent, AgentOS
from agno.models.openai import OpenAIChat
from agno.tools.duckduckgo import DuckDuckGoTools
from agno.tools.shell import ShellTools
from agno.tools.file import FileTools
from agno.tools.python import PythonTools
from agno.knowledge.pdf import PDFKnowledgeBase
from agno.storage.postgres import PostgresDb
import os

# Browser automation imports
try:
    from agno.tools.browserbase import BrowserbaseTools
    BROWSERBASE_AVAILABLE = True
except ImportError:
    BROWSERBASE_AVAILABLE = False

try:
    from playwright.sync_api import sync_playwright
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False

try:
    from selenium import webdriver
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    SELENIUM_AVAILABLE = True
except ImportError:
    SELENIUM_AVAILABLE = False

# Configure OpenAI model (requires OPENAI_API_KEY)
model = OpenAIChat(
    model="gpt-4o-mini",
    temperature=0.1,
    max_tokens=4000
)

# DevOps Assistant Agent
devops_agent = Agent(
    name="AI DevOps Assistant",
    description="Expert AI assistant for DevOps operations, infrastructure management, and automation",
    model=model,
    tools=[
        DuckDuckGoTools(),
        ShellTools(run_code=False),  # Safe mode - no code execution
        FileTools(),
        PythonTools(run_code=False),  # Safe mode - no code execution
    ],
    instructions=[
        "You are an expert DevOps assistant specializing in:",
        "- Infrastructure automation and management",
        "- CI/CD pipeline optimization", 
        "- Cloud platform integration",
        "- Security best practices",
        "- Monitoring and observability",
        "- Container orchestration",
        "Always provide safe, well-documented solutions.",
        "Explain your reasoning and include relevant examples.",
        "Focus on enterprise-grade, production-ready approaches."
    ],
    show_tool_calls=True,
    markdown=True
)

# Code Review Agent
code_review_agent = Agent(
    name="Code Review Assistant",
    description="AI assistant for code review, quality analysis, and best practices",
    model=model,
    tools=[
        FileTools(),
        PythonTools(run_code=False),
    ],
    instructions=[
        "You are an expert code reviewer focusing on:",
        "- Code quality and best practices",
        "- Security vulnerability detection",
        "- Performance optimization opportunities",
        "- Documentation and maintainability",
        "- Testing coverage and strategies",
        "Provide constructive feedback with specific examples.",
        "Suggest improvements with code snippets when helpful.",
        "Prioritize security and maintainability."
    ],
    show_tool_calls=True,
    markdown=True
)

# Documentation Agent
docs_agent = Agent(
    name="Documentation Assistant",
    description="AI assistant for creating and maintaining technical documentation",
    model=model,
    tools=[
        FileTools(),
        DuckDuckGoTools(),
    ],
    instructions=[
        "You are an expert technical writer specializing in:",
        "- API documentation and guides",
        "- Architecture documentation",
        "- User manuals and tutorials",
        "- README files and project documentation",
        "- Runbooks and operational procedures",
        "Create clear, comprehensive, and well-structured documentation.",
        "Use appropriate formatting and include examples.",
        "Focus on user experience and clarity."
    ],
    show_tool_calls=True,
    markdown=True
)

# LinkedIn Automation Agent
linkedin_tools = []
if BROWSERBASE_AVAILABLE:
    linkedin_tools.append(BrowserbaseTools())

linkedin_agent = Agent(
    name="LinkedIn Automation Assistant",
    description="AI assistant for LinkedIn automation and social media management",
    model=model,
    tools=linkedin_tools + [
        FileTools(),
        PythonTools(run_code=False),  # Safe mode
    ],
    instructions=[
        "You are a LinkedIn automation specialist focusing on:",
        "- Automated post engagement (liking, commenting)",
        "- Timeline monitoring and content analysis",
        "- Connection management and networking",
        "- Content scheduling and posting",
        "- Profile optimization and management",
        "- Analytics and engagement tracking",
        "IMPORTANT SAFETY GUIDELINES:",
        "- Always respect LinkedIn's Terms of Service",
        "- Use reasonable delays between actions (2-5 seconds)",
        "- Limit daily actions to avoid rate limiting",
        "- Never spam or engage in inappropriate behavior",
        "- Respect user privacy and data protection",
        "- Provide ethical automation strategies only",
        "Focus on authentic engagement and professional networking."
    ],
    show_tool_calls=True,
    markdown=True
)

# Web Automation Agent
web_automation_agent = Agent(
    name="Web Automation Assistant",
    description="AI assistant for general web automation and browser tasks",
    model=model,
    tools=linkedin_tools + [
        FileTools(),
        PythonTools(run_code=False),  # Safe mode
    ],
    instructions=[
        "You are a web automation expert specializing in:",
        "- Browser automation with Playwright and Selenium",
        "- Web scraping and data extraction",
        "- Form filling and submission automation",
        "- Website monitoring and testing",
        "- Social media automation (ethical)",
        "- E-commerce automation and monitoring",
        "IMPORTANT GUIDELINES:",
        "- Always respect website Terms of Service",
        "- Use appropriate delays and rate limiting",
        "- Handle errors gracefully with retries",
        "- Respect robots.txt and website policies",
        "- Provide ethical automation solutions only",
        "- Focus on legitimate business use cases",
        "Create robust, maintainable automation scripts."
    ],
    show_tool_calls=True,
    markdown=True
)

# Create AgentOS instance
available_agents = [devops_agent, code_review_agent, docs_agent]

# Add browser automation agents if tools are available
if BROWSERBASE_AVAILABLE or PLAYWRIGHT_AVAILABLE or SELENIUM_AVAILABLE:
    available_agents.extend([linkedin_agent, web_automation_agent])
    print("🌐 Browser automation agents enabled")
else:
    print("⚠️  Browser automation tools not available - install with: pip install playwright selenium")

agent_os = AgentOS(
    name="AI DevOps AgentOS",
    agents=available_agents,
    port=int(os.getenv("AGNO_PORT", "8000")),
    debug=True
)

if __name__ == "__main__":
    print("🚀 Starting AI DevOps AgentOS...")
    print(f"📊 Available Agents: {len(agent_os.agents)}")
    print(f"🌐 Server will run on: http://localhost:{agent_os.port}")
    print("💡 Use Ctrl+C to stop the server")
    
    agent_os.serve()
EOF
        print_success "Created AgentOS configuration"
    fi
    
    # Create environment template
    if [[ ! -f ".env.example" ]]; then
        cat > .env.example << 'EOF'
# AI DevOps Framework - Agno Configuration
# Copy this file to .env and configure your API keys

# OpenAI Configuration (Required)
OPENAI_API_KEY=your_openai_api_key_here

# Agno Configuration
AGNO_PORT=8000
AGNO_DEBUG=true

# Optional: Database Configuration
# DATABASE_URL=postgresql://user:password@localhost:5432/agno_db

# Optional: Additional Model Providers
# ANTHROPIC_API_KEY=your_anthropic_key_here
# GOOGLE_API_KEY=your_google_key_here
# GROQ_API_KEY=your_groq_key_here
EOF
        print_success "Created environment template"
    fi
    
    # Create startup script
    cat > start_agno.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
source venv/bin/activate
python agent_os.py
EOF
    chmod +x start_agno.sh
    
    print_success "Agno AgentOS setup complete"
    print_info "Directory: $AGNO_DIR"
    print_info "Configure your API keys in .env file"
}

# Function to setup Agent-UI
setup_agent_ui() {
    print_info "Setting up Agent-UI..."
    
    # Create directory
    mkdir -p "$AGENT_UI_DIR"
    cd "$AGENT_UI_DIR"
    
    # Check if already initialized
    if [[ ! -f "package.json" ]]; then
        print_info "Creating Agent-UI project..."
        npx create-agent-ui@latest . --yes
    else
        print_info "Agent-UI already initialized, updating dependencies..."
        npm install
    fi
    
    # Create configuration
    if [[ ! -f ".env.local" ]]; then
        cat > .env.local << EOF
# Agent-UI Configuration for AI DevOps Framework
NEXT_PUBLIC_AGNO_API_URL=http://localhost:${AGNO_PORT}
NEXT_PUBLIC_APP_NAME=AI DevOps Assistant
NEXT_PUBLIC_APP_DESCRIPTION=AI-powered DevOps automation and assistance
PORT=${AGENT_UI_PORT}
EOF
        print_success "Created Agent-UI configuration"
    fi
    
    # Create startup script
    cat > start_agent_ui.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
npm run dev
EOF
    chmod +x start_agent_ui.sh
    
    print_success "Agent-UI setup complete"
    print_info "Directory: $AGENT_UI_DIR"
}

# Function to create management scripts
create_management_scripts() {
    print_info "Creating management scripts..."

    local script_dir="$HOME/.aidevops/scripts"
    mkdir -p "$script_dir"

    # Create unified start script
    cat > "$script_dir/start-agno-stack.sh" << 'EOF'
#!/bin/bash

# AI DevOps Framework - Agno Stack Startup Script
# Starts both AgentOS and Agent-UI in the background

AGNO_DIR="$HOME/.aidevops/agno"
AGENT_UI_DIR="$HOME/.aidevops/agent-ui"

echo "🚀 Starting AI DevOps Agno Stack..."

# Start AgentOS in background
if [[ -f "$AGNO_DIR/start_agno.sh" ]]; then
    echo "📡 Starting AgentOS..."
    cd "$AGNO_DIR"
    ./start_agno.sh &
    AGNO_PID=$!
    echo "AgentOS PID: $AGNO_PID"
    sleep 3
else
    echo "❌ AgentOS not found. Run setup first."
    exit 1
fi

# Start Agent-UI in background
if [[ -f "$AGENT_UI_DIR/start_agent_ui.sh" ]]; then
    echo "🎨 Starting Agent-UI..."
    cd "$AGENT_UI_DIR"
    ./start_agent_ui.sh &
    AGENT_UI_PID=$!
    echo "Agent-UI PID: $AGENT_UI_PID"
    sleep 3
else
    echo "❌ Agent-UI not found. Run setup first."
    kill $AGNO_PID 2>/dev/null
    exit 1
fi

echo ""
echo "✅ AI DevOps Agno Stack Started Successfully!"
echo "📡 AgentOS: http://localhost:8000"
echo "🎨 Agent-UI: http://localhost:3000"
echo ""
echo "💡 Use 'stop-agno-stack.sh' to stop all services"
echo "📊 Use 'agno-status.sh' to check service status"

# Save PIDs for later cleanup
echo "$AGNO_PID" > /tmp/agno_pid
echo "$AGENT_UI_PID" > /tmp/agent_ui_pid

# Keep script running to monitor services
wait
EOF
    chmod +x "$script_dir/start-agno-stack.sh"

    # Create stop script
    cat > "$script_dir/stop-agno-stack.sh" << 'EOF'
#!/bin/bash

echo "🛑 Stopping AI DevOps Agno Stack..."

# Stop services by PID
if [[ -f /tmp/agno_pid ]]; then
    AGNO_PID=$(cat /tmp/agno_pid)
    if kill -0 "$AGNO_PID" 2>/dev/null; then
        echo "📡 Stopping AgentOS (PID: $AGNO_PID)..."
        kill "$AGNO_PID"
    fi
    rm -f /tmp/agno_pid
fi

if [[ -f /tmp/agent_ui_pid ]]; then
    AGENT_UI_PID=$(cat /tmp/agent_ui_pid)
    if kill -0 "$AGENT_UI_PID" 2>/dev/null; then
        echo "🎨 Stopping Agent-UI (PID: $AGENT_UI_PID)..."
        kill "$AGENT_UI_PID"
    fi
    rm -f /tmp/agent_ui_pid
fi

# Fallback: kill by port
echo "🔍 Checking for remaining processes..."
pkill -f "python.*agent_os.py" 2>/dev/null
pkill -f "npm.*run.*dev" 2>/dev/null

echo "✅ AI DevOps Agno Stack stopped"
EOF
    chmod +x "$script_dir/stop-agno-stack.sh"

    # Create status script
    cat > "$script_dir/agno-status.sh" << 'EOF'
#!/bin/bash

echo "📊 AI DevOps Agno Stack Status"
echo "================================"

# Check AgentOS
if curl -s http://localhost:8000/health >/dev/null 2>&1; then
    echo "📡 AgentOS: ✅ Running (http://localhost:8000)"
else
    echo "📡 AgentOS: ❌ Not running"
fi

# Check Agent-UI
if curl -s http://localhost:3000 >/dev/null 2>&1; then
    echo "🎨 Agent-UI: ✅ Running (http://localhost:3000)"
else
    echo "🎨 Agent-UI: ❌ Not running"
fi

echo ""
echo "🔧 Process Information:"
ps aux | grep -E "(agent_os\.py|npm.*run.*dev)" | grep -v grep || echo "No Agno processes found"
EOF
    chmod +x "$script_dir/agno-status.sh"

    print_success "Management scripts created in $script_dir"
}

# Function to show usage information
show_usage() {
    echo "AI DevOps Framework - Agno Setup"
    echo ""
    echo "Usage: $0 [action]"
    echo ""
    echo "Actions:"
    echo "  setup     Complete setup of Agno + Agent-UI"
    echo "  agno      Setup only Agno AgentOS"
    echo "  ui        Setup only Agent-UI"
    echo "  check     Check prerequisites"
    echo "  status    Show current status"
    echo "  start     Start the Agno stack"
    echo "  stop      Stop the Agno stack"
    echo ""
    echo "Examples:"
    echo "  $0 setup    # Full setup"
    echo "  $0 start    # Start services"
    echo "  $0 status   # Check status"
}

# Main function
main() {
    local action="$1"

    case "$action" in
        "setup")
            if check_prerequisites; then
                setup_agno
                setup_agent_ui
                create_management_scripts
                echo ""
                print_success "🎉 AI DevOps Agno Stack setup complete!"
                echo ""
                echo "📋 Next Steps:"
                echo "1. Configure API keys in $AGNO_DIR/.env"
                echo "2. Start services: ~/.aidevops/scripts/start-agno-stack.sh"
                echo "3. Access Agent-UI: http://localhost:3000"
                echo "4. Access AgentOS API: http://localhost:8000"
            fi
            ;;
        "agno")
            if check_prerequisites; then
                setup_agno
            fi
            ;;
        "ui")
            if check_prerequisites; then
                setup_agent_ui
            fi
            ;;
        "check")
            check_prerequisites
            ;;
        "status")
            if [[ -f "$HOME/.aidevops/scripts/agno-status.sh" ]]; then
                "$HOME/.aidevops/scripts/agno-status.sh"
            else
                print_error "Agno stack not set up. Run '$0 setup' first."
            fi
            ;;
        "start")
            if [[ -f "$HOME/.aidevops/scripts/start-agno-stack.sh" ]]; then
                "$HOME/.aidevops/scripts/start-agno-stack.sh"
            else
                print_error "Agno stack not set up. Run '$0 setup' first."
            fi
            ;;
        "stop")
            if [[ -f "$HOME/.aidevops/scripts/stop-agno-stack.sh" ]]; then
                "$HOME/.aidevops/scripts/stop-agno-stack.sh"
            else
                print_error "Agno stack not set up. Run '$0 setup' first."
            fi
            ;;
        *)
            show_usage
            ;;
    esac
}

main "$@"
