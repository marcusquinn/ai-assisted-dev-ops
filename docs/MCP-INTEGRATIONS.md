# 🚀 Advanced MCP Integrations for AI DevOps

This document provides comprehensive setup and usage instructions for advanced Model Context Protocol (MCP) integrations that dramatically expand our AI development capabilities.

## 📋 **Available MCP Integrations**

### **🌐 Web & Browser Automation**

- **Chrome DevTools MCP**: Browser automation, debugging, performance analysis
- **Playwright MCP**: Cross-browser testing and automation
- **Cloudflare Browser Rendering**: Server-side web scraping and rendering

### **🔍 SEO & Research Tools**

- **Ahrefs MCP**: SEO analysis, backlink research, keyword data
- **Perplexity MCP**: AI-powered web search and research
- **Google Search Console MCP**: Search performance data and insights

### **⚡ Development Tools**

- **Next.js DevTools MCP**: Next.js development and debugging assistance

### **📚 Legacy MCP Servers (from MCP-SERVERS.md)**

- **Context7 MCP**: Real-time documentation access for development libraries
- **LocalWP MCP**: Direct WordPress database access for local development

## 🎯 **Quick Setup Commands**

### **Chrome DevTools MCP**

```bash
# Add to Claude Desktop
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest

# Add to VS Code Copilot
code --add-mcp '{"name":"chrome-devtools","command":"npx","args":["chrome-devtools-mcp@latest"]}'

# Manual configuration
npx chrome-devtools-mcp@latest --channel=canary --headless=true
```

### **Playwright MCP**

```bash
# Install Playwright MCP
npm install -g playwright-mcp
playwright-mcp --install-browsers

# Add to MCP client
claude mcp add playwright npx playwright-mcp@latest
```

### **Ahrefs MCP**

```bash
# Setup Ahrefs API integration
export AHREFS_API_KEY="your_api_key_here"
claude mcp add ahrefs npx ahrefs-mcp@latest
```

### **Perplexity MCP**

```bash
# Setup Perplexity integration
export PERPLEXITY_API_KEY="your_api_key_here"
claude mcp add perplexity npx perplexity-mcp@latest
```

### **Google Search Console MCP**

```bash
# Setup Google Search Console integration
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

## 🔧 **Configuration Examples**

### **Advanced Chrome DevTools Configuration**

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--isolated=true",
        "--viewport=1920x1080",
        "--logFile=/tmp/chrome-mcp.log"
      ]
    }
  }
}
```

### **Cloudflare Browser Rendering Configuration**

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": [
        "cloudflare-browser-rendering-mcp@latest",
        "--account-id=your_account_id",
        "--api-token=your_api_token"
      ]
    }
  }
}
```

## 📊 **Use Cases & Examples**

### **Web Scraping & Analysis**

- Extract data from websites using Chrome DevTools or Cloudflare Browser Rendering
- Perform SEO analysis with Ahrefs integration
- Research topics and gather information with Perplexity

### **Automated Testing**

- Cross-browser testing with Playwright
- Performance analysis with Chrome DevTools
- Visual regression testing and debugging

### **Development Assistance**

- Next.js development debugging and optimization
- Real-time browser inspection and manipulation
- API testing and validation

## 🔐 **Security & API Keys**

### **Required API Keys**

- **Ahrefs**: Get from [Ahrefs API Dashboard](https://ahrefs.com/api)
- **Perplexity**: Get from [Perplexity API](https://docs.perplexity.ai/)
- **Cloudflare**: Account ID and API token from Cloudflare dashboard

### **Environment Variables**

```bash
export AHREFS_API_KEY="your_ahrefs_key"
export PERPLEXITY_API_KEY="your_perplexity_key"
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
```

## 🚀 **Getting Started**

### **Quick Setup (All Integrations)**

```bash
# Install all MCP integrations
bash .agent/scripts/setup-mcp-integrations.sh all

# Validate setup
bash .agent/scripts/validate-mcp-integrations.sh
```

### **Individual Integration Setup**

```bash
# Install specific integration
bash .agent/scripts/setup-mcp-integrations.sh chrome-devtools
bash .agent/scripts/setup-mcp-integrations.sh playwright
bash .agent/scripts/setup-mcp-integrations.sh ahrefs
```

### **Configuration Steps**

1. **Choose your MCP integrations** based on your needs
2. **Run the setup script** for your selected integrations
3. **Configure API keys** using the provided templates
4. **Test integrations** with the validation script
5. **Start using** advanced AI-assisted development capabilities!

## 🎯 **Real-World Use Cases**

### **Web Development Workflow**

- **Chrome DevTools**: Debug performance issues, analyze Core Web Vitals
- **Playwright**: Automated cross-browser testing and E2E validation
- **Next.js DevTools**: Real-time development assistance and optimization

### **SEO & Content Strategy**

- **Ahrefs**: Keyword research, backlink analysis, competitor insights
- **Perplexity**: AI-powered research and content ideation
- **Cloudflare Browser Rendering**: Server-side content analysis

### **Quality Assurance**

- **Playwright**: Comprehensive test automation across browsers
- **Chrome DevTools**: Performance monitoring and debugging
- **Visual regression testing** with screenshot comparisons

## 📊 **Integration Status Dashboard**

Run the validation script to see your current setup status:

```bash
bash .agent/scripts/validate-mcp-integrations.sh
```

Expected output for fully configured setup:

```text
✅ Overall status: EXCELLENT (100% success rate)
✅ All MCP integrations are ready to use!
```

## 📚 **Additional Resources**

- [MCP Integration Setup Script](.agent/scripts/setup-mcp-integrations.sh)
- [MCP Validation Script](.agent/scripts/validate-mcp-integrations.sh)
- [MCP Configuration Templates](configs/mcp-templates/)
- [Chrome DevTools Examples](docs/mcp-examples/chrome-devtools-examples.md)
- [Playwright Automation Examples](docs/mcp-examples/playwright-automation-examples.md)
- [Troubleshooting Guide](docs/MCP-TROUBLESHOOTING.md)
