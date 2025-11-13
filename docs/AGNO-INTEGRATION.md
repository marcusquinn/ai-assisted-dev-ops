# 🤖 Agno Integration for AI DevOps Framework

**Run powerful AI agents locally with complete privacy and control**

## 🎯 **Overview**

The Agno integration brings enterprise-grade AI agent capabilities to the AI DevOps framework. Agno provides a production-ready agent operating system (AgentOS) that runs entirely within your infrastructure, ensuring complete data privacy and control.

## 🌟 **Key Features**

### **🔒 Privacy & Security**
- **Complete Data Ownership**: All processing happens locally
- **Zero Data Transmission**: No conversations sent to external services
- **Private by Default**: Enterprise-grade security and privacy
- **Your Infrastructure**: Runs entirely in your environment

### **🚀 Agent Capabilities**
- **Multi-Agent Framework**: Deploy specialized AI agents for different tasks
- **Production Runtime**: FastAPI-based server for reliable operation
- **Real-time Chat Interface**: Beautiful web UI for agent interaction
- **Tool Integration**: Extensive toolkit for DevOps operations

### **🛠️ DevOps-Optimized Agents**
- **DevOps Assistant**: Infrastructure automation and management
- **Code Review Agent**: Quality analysis and best practices
- **Documentation Agent**: Technical writing and documentation

## 📦 **Installation & Setup**

### **Prerequisites**

```bash
# Check requirements
python3 --version  # Requires Python 3.8+
node --version     # Requires Node.js 18+
npm --version      # Requires npm
```

### **Quick Setup**

```bash
# Run the setup script
bash providers/agno-setup.sh setup

# Configure API keys
nano ~/.aidevops/agno/.env

# Start the Agno stack
~/.aidevops/scripts/start-agno-stack.sh
```

### **Manual Installation**

#### **1. Setup Agno AgentOS**

```bash
# Create directory and virtual environment
mkdir -p ~/.aidevops/agno
cd ~/.aidevops/agno
python3 -m venv venv
source venv/bin/activate

# Install Agno with all features
pip install "agno[all]"
```

#### **2. Setup Agent-UI**

```bash
# Create Agent-UI project
mkdir -p ~/.aidevops/agent-ui
cd ~/.aidevops/agent-ui
npx create-agent-ui@latest . --yes
```

## 🔧 **Configuration**

### **Environment Variables**

Create `~/.aidevops/agno/.env`:

```bash
# OpenAI Configuration (Required)
OPENAI_API_KEY=your_openai_api_key_here

# Agno Configuration
AGNO_PORT=8000
AGNO_DEBUG=true

# Optional: Additional Model Providers
ANTHROPIC_API_KEY=your_anthropic_key_here
GOOGLE_API_KEY=your_google_key_here
GROQ_API_KEY=your_groq_key_here
```

### **Agent-UI Configuration**

Create `~/.aidevops/agent-ui/.env.local`:

```bash
NEXT_PUBLIC_AGNO_API_URL=http://localhost:8000
NEXT_PUBLIC_APP_NAME=AI DevOps Assistant
NEXT_PUBLIC_APP_DESCRIPTION=AI-powered DevOps automation
PORT=3000
```

## 🚀 **Usage**

### **Starting Services**

```bash
# Start both AgentOS and Agent-UI
~/.aidevops/scripts/start-agno-stack.sh

# Check status
~/.aidevops/scripts/agno-status.sh

# Stop services
~/.aidevops/scripts/stop-agno-stack.sh
```

### **Accessing the Interface**

- **Agent-UI**: http://localhost:3000 (Main chat interface)
- **AgentOS API**: http://localhost:8000 (REST API)
- **API Docs**: http://localhost:8000/docs (Swagger documentation)

## 🤖 **Available Agents**

### **1. DevOps Assistant**
**Specialization**: Infrastructure automation and management

**Capabilities**:
- Infrastructure automation and management
- CI/CD pipeline optimization
- Cloud platform integration
- Security best practices
- Monitoring and observability
- Container orchestration

**Tools**:
- Web search (DuckDuckGo)
- File operations
- Shell commands (safe mode)
- Python scripting (safe mode)

### **2. Code Review Assistant**
**Specialization**: Code quality analysis and best practices

**Capabilities**:
- Code quality and best practices analysis
- Security vulnerability detection
- Performance optimization opportunities
- Documentation and maintainability review
- Testing coverage and strategies

**Tools**:
- File operations
- Python code analysis

### **3. Documentation Assistant**
**Specialization**: Technical writing and documentation

**Capabilities**:
- API documentation and guides
- Architecture documentation
- User manuals and tutorials
- README files and project documentation
- Runbooks and operational procedures

**Tools**:
- File operations
- Web search for research
- Document generation

## 🔗 **Integration with AI DevOps Framework**

### **Workflow Integration**

```bash
# Convert documents for agent processing
bash providers/pandoc-helper.sh batch ./docs ./agent-ready "*.{docx,pdf}"

# Start Agno agents
~/.aidevops/scripts/start-agno-stack.sh

# Agents can now process converted documentation
# Example: "Analyze all documentation and create deployment guide"
```

### **API Integration**

```python
import requests

# Send message to DevOps agent
response = requests.post(
    "http://localhost:8000/v1/agents/devops-assistant/chat",
    json={
        "message": "Help me optimize our CI/CD pipeline",
        "stream": False
    }
)

print(response.json())
```

## 📊 **Advanced Configuration**

### **Custom Agents**

Add custom agents to `~/.aidevops/agno/agent_os.py`:

```python
# Security Audit Agent
security_agent = Agent(
    name="Security Audit Assistant",
    description="AI assistant for security auditing and compliance",
    model=model,
    tools=[FileTools(), ShellTools(run_code=False)],
    instructions=[
        "You are a security expert focusing on:",
        "- Security vulnerability assessment",
        "- Compliance checking and reporting", 
        "- Security best practices implementation",
        "- Threat modeling and risk assessment"
    ]
)

# Add to AgentOS
agent_os = AgentOS(
    agents=[devops_agent, code_review_agent, docs_agent, security_agent]
)
```

### **Database Integration**

```python
from agno.storage.postgres import PostgresDb

# Configure persistent storage
storage = PostgresDb(
    host="localhost",
    port=5432,
    user="agno_user",
    password="agno_password",
    database="agno_db"
)

# Add to agents
devops_agent.storage = storage
```

### **Knowledge Base Integration**

```python
from agno.knowledge.pdf import PDFKnowledgeBase

# Create knowledge base from documentation
kb = PDFKnowledgeBase(
    path="./documentation",
    vector_db=ChromaDb()
)

# Add to agents
devops_agent.knowledge_base = kb
```

## 🔧 **Management Commands**

### **Service Management**

```bash
# Setup (one-time)
bash providers/agno-setup.sh setup

# Service control
~/.aidevops/scripts/start-agno-stack.sh    # Start services
~/.aidevops/scripts/stop-agno-stack.sh     # Stop services
~/.aidevops/scripts/agno-status.sh         # Check status

# Individual components
bash providers/agno-setup.sh agno          # Setup only AgentOS
bash providers/agno-setup.sh ui            # Setup only Agent-UI
bash providers/agno-setup.sh check         # Check prerequisites
```

### **Development Commands**

```bash
# Update Agno
cd ~/.aidevops/agno
source venv/bin/activate
pip install --upgrade "agno[all]"

# Update Agent-UI
cd ~/.aidevops/agent-ui
npm update

# View logs
tail -f ~/.aidevops/agno/agno.log
tail -f ~/.aidevops/agent-ui/.next/trace
```

## 🚨 **Troubleshooting**

### **Common Issues**

#### **Port Conflicts**
```bash
# Check what's using ports
lsof -i :8000  # AgentOS
lsof -i :3000  # Agent-UI

# Change ports in configuration
export AGNO_PORT=8001
export AGENT_UI_PORT=3001
```

#### **API Key Issues**
```bash
# Verify API key configuration
cd ~/.aidevops/agno
source venv/bin/activate
python -c "import os; print('OPENAI_API_KEY:', 'SET' if os.getenv('OPENAI_API_KEY') else 'NOT SET')"
```

#### **Permission Issues**
```bash
# Fix script permissions
chmod +x ~/.aidevops/scripts/*.sh
chmod +x ~/.aidevops/agno/start_agno.sh
chmod +x ~/.aidevops/agent-ui/start_agent_ui.sh
```

### **Performance Optimization**

#### **Memory Usage**
```bash
# Monitor memory usage
ps aux | grep -E "(python.*agent_os|npm.*run.*dev)"

# Optimize Python memory
export PYTHONOPTIMIZE=1
export PYTHONDONTWRITEBYTECODE=1
```

#### **Response Speed**
```python
# Optimize model configuration
model = OpenAIChat(
    model="gpt-4o-mini",  # Faster than gpt-4
    temperature=0.1,      # Lower for consistency
    max_tokens=2000,      # Limit for speed
    timeout=30            # Reasonable timeout
)
```

## 🌟 **Best Practices**

### **Security**
- **API Keys**: Store in `.env` files, never commit to version control
- **Network**: Run on localhost only for development
- **Access**: Use authentication for production deployments
- **Updates**: Keep Agno and dependencies updated

### **Performance**
- **Model Selection**: Use appropriate models for tasks (gpt-4o-mini for speed)
- **Tool Limits**: Enable safe mode for shell and Python tools
- **Memory**: Monitor memory usage with multiple agents
- **Caching**: Enable response caching for development

### **Development**
- **Testing**: Test agents individually before integration
- **Logging**: Enable debug mode during development
- **Monitoring**: Use status scripts to monitor services
- **Backup**: Backup agent configurations and knowledge bases

## 🔗 **Integration Examples**

### **With Pandoc Conversion**
```bash
# Convert documents for agent processing
bash providers/pandoc-helper.sh batch ./project-docs ./agent-ready

# Ask agent to analyze converted docs
# "Analyze the converted documentation and create a deployment checklist"
```

### **With Version Management**
```bash
# Get current version for agent context
VERSION=$(bash .agent/scripts/version-manager.sh get)

# Ask agent to help with release
# "Help me prepare release notes for version $VERSION"
```

### **With Quality Monitoring**
```bash
# Ask agent to review quality reports
# "Review the latest SonarCloud analysis and suggest improvements"
```

## 📈 **Benefits for AI DevOps**

- **🔒 Complete Privacy**: All AI processing happens locally
- **🚀 Production Ready**: Enterprise-grade agent runtime
- **🛠️ DevOps Focused**: Specialized agents for DevOps tasks
- **📊 Comprehensive**: Covers entire DevOps lifecycle
- **🔄 Integrated**: Works seamlessly with existing framework tools
- **📝 Documented**: Extensive documentation and examples
- **🎯 Specialized**: Purpose-built agents for specific tasks

---

**Transform your DevOps workflows with local AI agents powered by Agno!** 🤖🚀✨
