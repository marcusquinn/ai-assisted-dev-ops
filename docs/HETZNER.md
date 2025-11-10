# Hetzner Cloud Provider Guide

Hetzner Cloud is a German cloud infrastructure provider known for excellent price-to-performance ratio, reliable service, and developer-friendly features.

## 🏢 **Provider Overview**

### **Hetzner Cloud Characteristics:**

- **Infrastructure Type**: Cloud VPS, Dedicated servers, Storage
- **Locations**: Germany, Finland, USA (Ashburn, Hillsboro)
- **API**: Comprehensive REST API with excellent documentation
- **SSH Access**: Full root access with SSH key authentication
- **Pricing**: Exceptional price-to-performance ratio
- **Performance**: High-performance SSD storage, fast networking
- **Reliability**: 99.9% uptime SLA, German engineering quality

### **Best Use Cases:**

- **Production applications** requiring reliable infrastructure
- **Development and staging** environments
- **High-performance computing** workloads
- **Cost-effective scaling** for growing applications
- **European data residency** requirements
- **Docker and Kubernetes** deployments

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/hetzner-config.json.txt configs/hetzner-config.json

# Edit with your actual API tokens and server details
```

### **Multi-Account Configuration:**

```json
{
  "accounts": {
    "main": {
      "api_token": "YOUR_MAIN_HETZNER_API_TOKEN_HERE",
      "description": "Main production account",
      "account": "your-email@domain.com"
    },
    "client-project": {
      "api_token": "YOUR_CLIENT_PROJECT_HETZNER_API_TOKEN_HERE",
      "description": "Client project account",
      "account": "your-email@domain.com"
    },
    "storagebox": {
      "api_token": "YOUR_STORAGEBOX_HETZNER_API_TOKEN_HERE",
      "description": "Storage and backup account",
      "account": "your-email@domain.com"
    }
  },
  "mcp_integration": {
    "enabled": true,
    "base_port": 8081,
    "notes": "MCP servers will use sequential ports starting from base_port"
  }
}
```

### **API Token Setup:**

1. **Login to Hetzner Cloud Console**
2. **Go to Security** → API Tokens
3. **Create new token** with appropriate permissions
4. **Copy token** to your configuration file
5. **Test access** with API call

## 🚀 **Usage Examples**

### **Server Management:**

```bash
# List all servers across accounts
./providers/hetzner-helper.sh list

# List servers for specific account
./providers/hetzner-helper.sh list main

# Create new server
./providers/hetzner-helper.sh create main web-server cx11 ubuntu-20.04

# Connect to server
./providers/hetzner-helper.sh connect main web-server

# Server operations
./providers/hetzner-helper.sh start main web-server
./providers/hetzner-helper.sh stop main web-server
./providers/hetzner-helper.sh reboot main web-server
```

### **API Operations:**

```bash
# Raw API calls
./providers/hetzner-helper.sh api main servers GET
./providers/hetzner-helper.sh api main images GET
./providers/hetzner-helper.sh api main server-types GET

# Server details
./providers/hetzner-helper.sh api main servers/12345 GET
```

### **MCP Server Integration:**

```bash
# Start MCP server for specific account
./providers/hetzner-helper.sh mcp-start main

# Test MCP server
curl http://localhost:8081/health
```

## 🛡️ **Security Best Practices**

### **API Token Security:**

- **Separate tokens**: Use different tokens for different projects
- **Minimal permissions**: Grant only required permissions
- **Regular rotation**: Rotate tokens every 6-12 months
- **Secure storage**: Store tokens in secure configuration files
- **Environment variables**: Use env vars in CI/CD pipelines

### **Server Security:**

```bash
# SSH key management
./providers/hetzner-helper.sh exec main web-server 'cat ~/.ssh/authorized_keys'

# Firewall configuration
./providers/hetzner-helper.sh exec main web-server 'ufw status'

# Security updates
./providers/hetzner-helper.sh exec main web-server 'apt update && apt upgrade -y'
```

### **Network Security:**

- **Private networks**: Use Hetzner private networks for internal communication
- **Firewalls**: Configure Hetzner Cloud Firewalls
- **Load balancers**: Use Hetzner Load Balancers for high availability
- **Floating IPs**: Use floating IPs for failover scenarios

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **API Authentication Errors:**

```bash
# Verify API token
curl -H "Authorization: Bearer YOUR_TOKEN" https://api.hetzner.cloud/v1/servers

# Check token permissions
# Ensure token has required scopes (read, write)
```

#### **SSH Connection Issues:**

```bash
# Check server status
./providers/hetzner-helper.sh api main servers/12345 GET

# Verify SSH key is added
./providers/hetzner-helper.sh api main ssh_keys GET

# Check firewall rules
./providers/hetzner-helper.sh api main firewalls GET
```

#### **Server Performance Issues:**

```bash
# Check server metrics
./providers/hetzner-helper.sh exec main web-server 'htop'
./providers/hetzner-helper.sh exec main web-server 'iostat -x 1'

# Monitor network
./providers/hetzner-helper.sh exec main web-server 'iftop'
```

## 📊 **Performance Optimization**

### **Server Types:**

- **CX series**: Shared vCPU, cost-effective
- **CPX series**: Dedicated vCPU, consistent performance
- **CCX series**: Dedicated CPU, high-performance computing

### **Storage Options:**

- **Local SSD**: High IOPS, included with server
- **Volumes**: Network-attached storage, scalable
- **Snapshots**: Point-in-time backups

### **Networking:**

```bash
# Private networks for internal communication
./providers/hetzner-helper.sh api main networks POST

# Load balancers for high availability
./providers/hetzner-helper.sh api main load_balancers POST

# Floating IPs for failover
./providers/hetzner-helper.sh api main floating_ips POST
```

## 🔄 **Backup & Disaster Recovery**

### **Automated Backups:**

```bash
# Enable automatic backups
./providers/hetzner-helper.sh api main servers/12345/actions/enable_backup POST

# Create manual snapshot
./providers/hetzner-helper.sh api main servers/12345/actions/create_image POST
```

### **Volume Snapshots:**

```bash
# Create volume snapshot
./providers/hetzner-helper.sh api main volumes/12345/actions/create_snapshot POST

# Restore from snapshot
./providers/hetzner-helper.sh api main volumes POST
```

## 🐳 **Container & Kubernetes**

### **Docker Setup:**

```bash
# Install Docker
./providers/hetzner-helper.sh exec main web-server 'curl -fsSL https://get.docker.com | sh'

# Docker Compose
./providers/hetzner-helper.sh exec main web-server 'curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose'
```

### **Kubernetes Integration:**

- **Hetzner Cloud Controller Manager**: For Kubernetes integration
- **CSI Driver**: For persistent volume support
- **Load Balancer**: Automatic load balancer provisioning

## 📚 **Best Practices**

### **Infrastructure as Code:**

```bash
# Use Terraform for infrastructure management
# Hetzner provider available
terraform init
terraform plan
terraform apply
```

### **Monitoring & Alerting:**

- **Prometheus**: For metrics collection
- **Grafana**: For visualization
- **AlertManager**: For alerting
- **Uptime monitoring**: External monitoring services

### **Cost Optimization:**

- **Right-sizing**: Choose appropriate server types
- **Scheduling**: Use scheduling for development environments
- **Snapshots**: Regular cleanup of old snapshots
- **Monitoring**: Track resource utilization

## 🎯 **AI Assistant Integration**

### **Automated Infrastructure:**

- **Auto-scaling**: Automated server provisioning
- **Health monitoring**: Automated health checks
- **Backup management**: Automated backup scheduling
- **Security updates**: Automated security patching
- **Cost monitoring**: Automated cost tracking and alerts

### **Development Workflows:**

- **Environment provisioning**: Automated dev/staging environments
- **CI/CD integration**: Automated deployments
- **Testing environments**: Ephemeral test environments
- **Database management**: Automated database operations

---

**Hetzner Cloud provides exceptional value with enterprise-grade features, making it ideal for production workloads and cost-conscious scaling.** 🚀
