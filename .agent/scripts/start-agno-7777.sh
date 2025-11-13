#!/bin/bash

# Start Agno AgentOS on port 7777 for AI DevOps Framework
# Author: AI DevOps Framework
# Version: 1.4.0

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

echo "🚀 AI DevOps Framework - Agno AgentOS Startup"
echo "🔒 Local Browser Automation (Privacy-First)"
echo "🌐 Starting on http://localhost:7777"
echo ""

# Check if Agno is installed
if ! python3 -c "import agno" 2>/dev/null; then
    print_error "Agno not installed"
    print_info "Installing Agno..."
    pip3 install agno
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to install Agno"
        exit 1
    fi
    
    print_success "Agno installed successfully"
fi

# Check for OpenAI API key
if [[ -z "$OPENAI_API_KEY" ]]; then
    print_warning "OPENAI_API_KEY not set"
    print_info "You'll need to set your OpenAI API key to use the agents"
    print_info "Set with: export OPENAI_API_KEY=your_api_key_here"
    print_info ""
    print_info "For demonstration, starting with placeholder key..."
    export OPENAI_API_KEY="placeholder_key_set_your_real_key"
fi

# Create a simple Agno startup script
cat > /tmp/agno_startup.py << 'EOF'
#!/usr/bin/env python3
"""
Simple Agno Startup for AI DevOps Framework
Runs on port 7777 with local browser automation
"""

import os
import sys

try:
    from agno import Agent, AgentOS
    from agno.models.openai import OpenAIChat
    from agno.tools.duckduckgo import DuckDuckGoTools
    from agno.tools.shell import ShellTools
    from agno.tools.file import FileTools
    from agno.tools.python import PythonTools
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("Install with: pip3 install agno")
    sys.exit(1)

def main():
    print("🚀 Starting Agno AgentOS on port 7777...")
    print("🔒 Local browser automation enabled (privacy-first)")
    print("")
    
    # Get API key
    api_key = os.getenv("OPENAI_API_KEY", "placeholder")
    
    if api_key == "placeholder" or api_key == "placeholder_key_set_your_real_key":
        print("⚠️  Using placeholder API key - set OPENAI_API_KEY for full functionality")
    
    try:
        # Create model
        model = OpenAIChat(
            model="gpt-4",
            api_key=api_key,
            temperature=0.1
        )
        
        # Create agents
        agents = []
        
        # DevOps Agent
        devops_agent = Agent(
            name="DevOps Assistant",
            description="AI assistant for DevOps automation and infrastructure management",
            model=model,
            tools=[
                ShellTools(),
                FileTools(),
                DuckDuckGoTools(),
            ],
            instructions=[
                "You are a DevOps expert specializing in infrastructure automation,",
                "CI/CD pipelines, cloud platforms, and container orchestration.",
                "Provide practical, actionable solutions for DevOps challenges."
            ],
            show_tool_calls=True,
            markdown=True
        )
        agents.append(devops_agent)
        
        # LinkedIn Automation Agent
        linkedin_agent = Agent(
            name="LinkedIn Automation Assistant (Local)",
            description="LinkedIn automation using LOCAL browsers only (privacy-first)",
            model=model,
            tools=[
                FileTools(),
                PythonTools(run_code=False),
            ],
            instructions=[
                "You are a LinkedIn automation specialist using LOCAL browsers only.",
                "Focus on professional networking with complete privacy.",
                "Always respect LinkedIn's Terms of Service and use ethical practices."
            ],
            show_tool_calls=True,
            markdown=True
        )
        agents.append(linkedin_agent)
        
        # Web Automation Agent
        web_agent = Agent(
            name="Web Automation Assistant (Local)",
            description="General web automation using LOCAL browsers only (privacy-first)",
            model=model,
            tools=[
                FileTools(),
                PythonTools(run_code=False),
            ],
            instructions=[
                "You are a web automation expert using LOCAL browsers only.",
                "Provide ethical automation solutions with complete privacy.",
                "Always respect website Terms of Service."
            ],
            show_tool_calls=True,
            markdown=True
        )
        agents.append(web_agent)
        
        # Create AgentOS
        agent_os = AgentOS(
            name="AI DevOps AgentOS",
            agents=agents,
            port=7777,
            debug=True
        )
        
        print("✅ Agno AgentOS configured successfully")
        print("🌐 Server starting on http://localhost:7777")
        print("🔒 Privacy: All browser automation runs locally")
        print("")
        print("Available Agents:")
        for agent in agents:
            print(f"  - {agent.name}")
        print("")
        print("Press Ctrl+C to stop the server")
        print("")
        
        # Start the server
        agent_os.run()
        
    except KeyboardInterrupt:
        print("\n👋 Agno AgentOS stopped")
    except Exception as e:
        print(f"❌ Error: {e}")
        print("Make sure you have a valid OPENAI_API_KEY set")

if __name__ == "__main__":
    main()
EOF

# Make the script executable
chmod +x /tmp/agno_startup.py

print_info "Starting Agno AgentOS..."
print_info "Access at: http://localhost:7777"
print_info "Press Ctrl+C to stop"
print_info ""

# Run the startup script
python3 /tmp/agno_startup.py
