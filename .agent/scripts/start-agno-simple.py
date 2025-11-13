#!/usr/bin/env python3
"""
Simple Agno Startup Script for AI DevOps Framework
Starts Agno AgentOS on port 7777 with local browser automation

Author: AI DevOps Framework
Version: 1.4.0
"""

import os
import sys

# Add the current directory to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from agno import Agent, AgentOS
    from agno.models.openai import OpenAIChat
    from agno.tools.duckduckgo import DuckDuckGoTools
    from agno.tools.shell import ShellTools
    from agno.tools.file import FileTools
    from agno.tools.python import PythonTools
except ImportError as e:
    print(f"❌ Agno not installed: {e}")
    print("Install with: pip install agno")
    sys.exit(1)

def create_agents():
    """Create AI agents for DevOps automation"""
    
    # Get OpenAI API key
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        print("❌ OPENAI_API_KEY environment variable not set")
        print("Set with: export OPENAI_API_KEY=your_api_key_here")
        sys.exit(1)
    
    # Create OpenAI model
    model = OpenAIChat(
        model="gpt-4",
        api_key=api_key,
        temperature=0.1
    )
    
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
            "You are a DevOps expert specializing in:",
            "- Infrastructure automation and management",
            "- CI/CD pipeline optimization",
            "- Cloud platform integration (AWS, Azure, GCP)",
            "- Container orchestration (Docker, Kubernetes)",
            "- Monitoring and observability",
            "- Security best practices",
            "Provide practical, actionable solutions for DevOps challenges.",
            "Focus on automation, scalability, and reliability."
        ],
        show_tool_calls=True,
        markdown=True
    )
    
    # LinkedIn Automation Agent (Local Browser Only)
    linkedin_agent = Agent(
        name="LinkedIn Automation Assistant (Local)",
        description="AI assistant for LinkedIn automation using LOCAL browsers only",
        model=model,
        tools=[
            FileTools(),
            PythonTools(run_code=False),  # Safe mode
        ],
        instructions=[
            "You are a LinkedIn automation specialist using LOCAL browsers only:",
            "- Automated post engagement using local Playwright/Selenium",
            "- Professional networking with complete privacy",
            "- Timeline monitoring using local browser instances",
            "- Connection management through local automation",
            "SECURITY & PRIVACY FIRST:",
            "- ALL browser automation runs locally on user's machine",
            "- NO data sent to cloud services or external browsers",
            "- Complete privacy and security with local-only operation",
            "IMPORTANT SAFETY GUIDELINES:",
            "- Always respect LinkedIn's Terms of Service",
            "- Use reasonable delays between actions (2-5 seconds)",
            "- Limit daily actions to avoid rate limiting",
            "- Focus on authentic engagement and professional networking"
        ],
        show_tool_calls=True,
        markdown=True
    )
    
    # Web Automation Agent (Local Browser Only)
    web_automation_agent = Agent(
        name="Web Automation Assistant (Local)",
        description="AI assistant for general web automation using LOCAL browsers only",
        model=model,
        tools=[
            FileTools(),
            PythonTools(run_code=False),  # Safe mode
        ],
        instructions=[
            "You are a web automation expert using LOCAL browsers only:",
            "- Browser automation with LOCAL Playwright and Selenium instances",
            "- Web scraping and data extraction using local browser control",
            "- Form filling and submission automation with local browsers",
            "- Website monitoring and testing through local automation",
            "SECURITY & PRIVACY FIRST:",
            "- ALL browser automation runs locally on user's machine",
            "- NO data sent to cloud services or external browsers",
            "- Complete privacy and security with local-only operation",
            "IMPORTANT GUIDELINES:",
            "- Always respect website Terms of Service",
            "- Use appropriate delays and rate limiting",
            "- Handle errors gracefully with retries",
            "- Provide ethical automation solutions only"
        ],
        show_tool_calls=True,
        markdown=True
    )
    
    return [devops_agent, linkedin_agent, web_automation_agent]

def main():
    """Main function to start Agno AgentOS"""
    print("🚀 Starting Agno AgentOS on port 7777...")
    print("🔒 Local browser automation enabled (privacy-first)")
    print("")
    
    try:
        # Create agents
        agents = create_agents()
        
        # Create AgentOS instance
        agent_os = AgentOS(
            name="AI DevOps AgentOS",
            agents=agents,
            port=7777,
            debug=True
        )
        
        print("✅ Agno AgentOS configured successfully")
        print("🌐 Starting server on http://localhost:7777")
        print("🔒 Privacy: All browser automation runs locally")
        print("")
        print("Available Agents:")
        for agent in agents:
            print(f"  - {agent.name}")
        print("")
        print("Press Ctrl+C to stop the server")
        
        # Start the server
        agent_os.run()
        
    except KeyboardInterrupt:
        print("\n👋 Agno AgentOS stopped")
    except Exception as e:
        print(f"❌ Error starting Agno AgentOS: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
