# MCP Servers Configuration Guide

Model Context Protocol (MCP) servers provide AI assistants with real-time access to external data sources and services, enabling dynamic and contextual interactions.

## 🏢 **MCP Overview**

### **MCP Characteristics:**

- **Protocol**: Standardized protocol for AI-external service communication
- **Real-time Data**: Live access to databases, APIs, and services
- **Contextual**: Provides relevant context to AI conversations
- **Extensible**: Easy to add new data sources and services
- **Secure**: Built-in authentication and access control

### **Available MCP Servers:**

- **Context7 MCP** - Real-time documentation access for development libraries
- **LocalWP MCP** - Direct WordPress database access for local development
- **Custom MCP Servers** - Project-specific data sources and services

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/mcp-servers-config.json.txt configs/mcp-servers-config.json

# Edit with your actual MCP server configurations
```

### **Multi-Server Configuration:**

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server@latest"],
      "env": {
        "DEBUG": "false"
      },
      "description": "Real-time documentation access",
      "status": "active"
    },
    "localwp": {
      "command": "node",
      "args": ["/path/to/localwp-mcp-server/index.js"],
      "env": {
        "LOCALWP_SITES_PATH": "/Users/username/Local Sites",
        "MCP_PORT": "3001"
      },
      "description": "LocalWP WordPress database access",
      "status": "active"
    },
    "custom-api": {
      "command": "node",
      "args": ["/path/to/custom-mcp-server/server.js"],
      "env": {
        "API_KEY": "your-api-key",
        "BASE_URL": "https://api.yourservice.com"
      },
      "description": "Custom API integration",
      "status": "inactive"
    }
  }
}
```

### **AI Assistant Integration:**

Different AI assistants have different MCP configuration methods:

#### **Claude Desktop:**

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server@latest"]
    },
    "localwp": {
      "command": "node",
      "args": ["/path/to/localwp-mcp-server/index.js"]
    }
  }
}
```

#### **Cursor IDE:**

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server@latest"]
    }
  }
}
```

## 🚀 **Usage Examples**

### **Context7 MCP Server:**

```bash
# Start Context7 MCP server
npx -y @context7/mcp-server@latest

# Query library documentation
# (Through AI assistant interface)
# "Get Next.js routing documentation"
# "Show me React hooks examples"
# "Find Supabase authentication guide"
```

### **LocalWP MCP Server:**

```bash
# Start LocalWP MCP server
./providers/localhost-helper.sh start-mcp

# Query WordPress database
# (Through AI assistant interface)
# "Show me the latest 5 blog posts"
# "List all WordPress users"
# "Get post content for post ID 123"
```

### **Custom MCP Servers:**

```bash
# Start custom MCP server
node /path/to/custom-mcp-server/server.js

# Query custom data sources
# (Through AI assistant interface)
# "Get customer data for account 12345"
# "Show recent API usage statistics"
# "List pending support tickets"
```

## 🛡️ **Security Best Practices**

### **MCP Server Security:**

- **Authentication**: Implement proper authentication for MCP servers
- **Access control**: Limit access to sensitive data sources
- **Encryption**: Use encrypted connections for data transmission
- **Audit logging**: Log all MCP server access and queries
- **Rate limiting**: Implement rate limiting to prevent abuse

### **Data Protection:**

```bash
# Secure MCP server configuration
chmod 600 configs/mcp-servers-config.json

# Use environment variables for sensitive data
export API_KEY="your-secure-api-key"
export DATABASE_PASSWORD="your-secure-password"

# Implement access controls
# Configure firewall rules for MCP server ports
# Use VPN or private networks for sensitive servers
```

### **Network Security:**

- **Private networks**: Run MCP servers on private networks when possible
- **Firewall rules**: Configure appropriate firewall rules
- **SSL/TLS**: Use encrypted connections for all MCP communications
- **IP restrictions**: Restrict access to trusted IP addresses
- **Regular updates**: Keep MCP servers and dependencies updated

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **MCP Server Connection Issues:**

```bash
# Check if MCP server is running
ps aux | grep mcp-server
netstat -tulpn | grep :3001

# Test MCP server connectivity
curl http://localhost:3001/health
telnet localhost 3001

# Check MCP server logs
tail -f /path/to/mcp-server/logs/server.log
```

#### **Configuration Issues:**

```bash
# Validate MCP configuration
jq '.' configs/mcp-servers-config.json

# Check environment variables
env | grep MCP
env | grep LOCALWP

# Verify file permissions
ls -la configs/mcp-servers-config.json
```

#### **AI Assistant Integration Issues:**

```bash
# Check AI assistant MCP configuration
# Verify MCP server is accessible from AI assistant
# Check AI assistant logs for MCP connection errors
# Restart AI assistant after MCP configuration changes
```

## 📊 **Monitoring & Management**

### **MCP Server Monitoring:**

```bash
# Monitor MCP server health
curl http://localhost:3001/health

# Check MCP server metrics
curl http://localhost:3001/metrics

# Monitor MCP server logs
tail -f /var/log/mcp-servers/context7.log
tail -f /var/log/mcp-servers/localwp.log
```

### **Performance Monitoring:**

```bash
# Monitor MCP server resource usage
ps aux | grep mcp-server
top -p $(pgrep mcp-server)

# Check network connections
netstat -an | grep :3001
ss -tulpn | grep :3001

# Monitor response times
time curl http://localhost:3001/api/query
```

## 🔄 **Development & Deployment**

### **Custom MCP Server Development:**

```javascript
// Basic MCP server structure
const express = require('express');
const app = express();

app.get('/health', (req, res) => {
    res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

app.post('/query', (req, res) => {
    // Handle MCP queries
    const { query } = req.body;
    // Process query and return results
    res.json({ results: processQuery(query) });
});

app.listen(3001, () => {
    console.log('MCP server running on port 3001');
});
```

### **Deployment Strategies:**

```bash
# Docker deployment
docker build -t custom-mcp-server .
docker run -d -p 3001:3001 custom-mcp-server

# PM2 process management
pm2 start mcp-server.js --name "custom-mcp"
pm2 save
pm2 startup

# Systemd service
sudo systemctl enable custom-mcp-server
sudo systemctl start custom-mcp-server
```

## 📚 **Best Practices**

### **MCP Server Design:**

1. **Stateless design**: Design MCP servers to be stateless when possible
2. **Error handling**: Implement comprehensive error handling
3. **Logging**: Implement detailed logging for debugging and monitoring
4. **Performance**: Optimize for fast response times
5. **Security**: Implement proper authentication and authorization

### **Configuration Management:**

- **Environment separation**: Use different configurations for dev/staging/prod
- **Secret management**: Use secure secret management for sensitive data
- **Version control**: Version control MCP server configurations
- **Documentation**: Document all MCP server configurations and APIs
- **Testing**: Test MCP servers thoroughly before deployment

### **Integration Patterns:**

- **Graceful degradation**: Handle MCP server unavailability gracefully
- **Caching**: Implement caching for frequently accessed data
- **Rate limiting**: Implement rate limiting to protect backend services
- **Monitoring**: Monitor MCP server health and performance
- **Alerting**: Set up alerts for MCP server issues

## 🎯 **AI Assistant Integration**

### **Enhanced AI Capabilities:**

- **Real-time data**: AI assistants can access live data from various sources
- **Contextual responses**: Responses based on current, relevant information
- **Dynamic queries**: AI can query databases and APIs in real-time
- **Multi-source integration**: Combine data from multiple sources
- **Personalized assistance**: Access to user-specific data and preferences

### **Development Workflows:**

- **Code assistance**: Real-time access to documentation and examples
- **Database queries**: Direct database access for development tasks
- **API integration**: Real-time API data for development decisions
- **Monitoring integration**: Access to system metrics and logs
- **Custom integrations**: Project-specific data sources and tools

---

**MCP servers provide powerful capabilities for AI assistants to access real-time data and services, enabling more contextual and useful interactions.** 🚀
