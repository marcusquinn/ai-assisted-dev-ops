# Best Practices & Provider Selection Guide

This guide outlines proven best practices for infrastructure management and helps you select the right providers for your needs, based on real-world production setups.

## 📚 **Available Providers**

### **🌐 Hosting & Cloud Providers**

- **[Hostinger](HOSTINGER.md)** - Budget-friendly web hosting with good performance
- **[Hetzner Cloud](HETZNER.md)** - German cloud provider with excellent price-to-performance
- **[Closte](CLOSTE.md)** - VPS hosting with competitive pricing
- **[Cloudron](CLOUDRON.md)** - Self-hosted app platform for easy application management

### **🚀 Deployment Platforms**

- **[Coolify](COOLIFY.md)** - Self-hosted alternative to Vercel/Netlify/Heroku
- **[Cloudron](CLOUDRON.md)** - Self-hosted app platform with easy management

### **📧 Email Services**

- **[Amazon SES](SES.md)** - Scalable email delivery with comprehensive monitoring

### **🎯 WordPress Management**

- **[MainWP](MAINWP.md)** - Self-hosted WordPress management platform

### **🔐 Security & Secrets Management**

- **[Vaultwarden](VAULTWARDEN.md)** - Self-hosted password and secrets management

### **🔍 Code Quality & Security**

- **[Code Auditing](CODE-AUDITING.md)** - Multi-platform code quality and security analysis

### **📚 Version Control & Git Platforms**

- **[Git Platforms](GIT-PLATFORMS.md)** - GitHub, GitLab, Gitea, and local Git management

### **🌐 Domain Management & Purchasing**

- **[Domain Purchasing](DOMAIN-PURCHASING.md)** - Automated domain purchasing and management

### **🌍 DNS & Domain Providers**

- **[Cloudflare DNS](CLOUDFLARE-SETUP.md)** - Global CDN and DNS with comprehensive API
- **[Spaceship](SPACESHIP.md)** - Modern domain registrar with developer-friendly API
- **[101domains](101DOMAINS.md)** - Comprehensive registrar with extensive TLD coverage
- **[Namecheap DNS](../configs/namecheap-dns-config.json.txt)** - Domain registrar with DNS management
- **[Route 53](../configs/route53-dns-config.json.txt)** - AWS DNS service with advanced features

### **🏠 Local Development**

- **[LocalWP](LOCALWP-MCP.md)** - Local WordPress development with MCP integration
- **[Localhost](LOCALHOST.md)** - Local development environment with .local domains
- **[Context7 MCP](CONTEXT7-MCP-SETUP.md)** - Real-time documentation access for AI assistants
- **[MCP Servers](MCP-SERVERS.md)** - Model Context Protocol server configuration

## 🎯 **Provider Selection Guide**

### **For Web Hosting:**

| Provider | Best For | Price Range | Key Features |
|----------|----------|-------------|--------------|
| **Hostinger** | Small-medium sites | $ | Easy management, good value |
| **Hetzner Cloud** | Production apps | $$ | Excellent performance, API |
| **Closte** | VPS hosting | $$ | Competitive pricing, flexibility |

### **For Application Deployment:**

| Platform | Best For | Complexity | Key Features |
|----------|----------|------------|--------------|
| **Coolify** | Self-hosted PaaS | Medium | Docker-based, full control |
| **Cloudron** | App management | Low | One-click apps, easy management |

### **For Email Delivery:**

| Service | Best For | Complexity | Key Features |
|---------|----------|------------|--------------|
| **Amazon SES** | Scalable email delivery | Medium | High deliverability, comprehensive analytics |

### **For DNS & Domain Management:**

| Provider | Best For | API Quality | Key Features |
|----------|----------|-------------|--------------|
| **Cloudflare** | Global performance | Excellent | CDN, security, analytics |
| **Spaceship** | Modern domain management | Excellent | Developer-friendly, competitive pricing |
| **101domains** | Large portfolios | Excellent | Extensive TLDs, privacy features |
| **Route 53** | AWS integration | Excellent | Advanced routing, health checks |
| **Namecheap** | Domain registration | Limited | Affordable, basic DNS |

## 🏗️ **Infrastructure Organization**

### **Multi-Project Architecture**

- **Separate API tokens** for different projects/clients
- **Descriptive naming**: Use clear project names (main, client-project, storagebox, client-projects)
- **Account isolation**: Keep production, development, and client projects separate
- **Documentation**: Maintain clear descriptions for each project/account

### **Hetzner Cloud Best Practices**

```json
{
  "accounts": {
    "main": {
      "api_token": "YOUR_MAIN_TOKEN",
      "description": "Main production account"
    },
    "client-project": {
      "api_token": "YOUR_CLIENT_PROJECT_TOKEN",
      "description": "Client project account"
    },
    "storagebox": {
      "api_token": "YOUR_STORAGE_TOKEN",
      "description": "Storage and backup account"
    }
  }
}
```

### **Hostinger Multi-Site Management**

- **Domain-based organization**: Group sites by domain/purpose
- **Consistent paths**: Use standard `/domains/[domain]/public_html` structure
- **Password management**: Separate password files for different server groups
- **Site categorization**: Group by client, project type, or environment

## 🔐 **Security Best Practices**

### **API Token Management**

- **Secure local storage**: Store tokens in `~/.config/ai-assisted-devops/` (user-private only)
- **Never in repository**: API tokens must never be stored in repository files
- **Environment separation**: Different tokens for prod/dev/staging
- **Regular rotation**: Rotate tokens quarterly
- **Least privilege**: Use minimal required permissions
- **Git exclusion**: Always add config files to `.gitignore`

### **SSH Key Standardization**

- **Modern keys**: Use Ed25519 keys (faster, more secure)
- **Key distribution**: Standardize keys across all servers
- **Passphrase protection**: Protect private keys with passphrases
- **Regular audits**: Audit and remove unused keys

### **Password Authentication (Hostinger/Closte)**

- **Secure storage**: Store passwords in separate files with 600 permissions
- **File naming**: Use descriptive names (`hostinger_password`, `closte_web_password`)
- **sshpass usage**: Use sshpass for automated password authentication
- **Git exclusion**: Add password files to `.gitignore`

## 🌐 **Domain & SSL Management**

### **Local Development Domains**

- **Consistent naming**: Use `.local` suffix for all local development
- **SSL by default**: Generate SSL certificates for all local domains
- **Port standardization**: Use consistent port ranges (10000+ for WordPress)
- **DNS resolution**: Setup dnsmasq for automatic `.local` resolution

### **LocalWP Integration**

- **Site naming**: Use descriptive names matching project purpose
- **Port mapping**: Map LocalWP ports to custom `.local` domains
- **SSL certificates**: Generate certificates for LocalWP sites
- **Traefik integration**: Use reverse proxy for clean domain access

### **Production SSL**

- **Let's Encrypt**: Use automated certificate generation
- **Wildcard certificates**: For multi-subdomain setups
- **Certificate monitoring**: Monitor expiration dates
- **Renewal automation**: Automate certificate renewal

## 🔧 **Development Environment Setup**

### **LocalWP Best Practices**

```bash
# List LocalWP sites
./providers/localhost-helper.sh list-localwp

# Setup custom domain for LocalWP site
./providers/localhost-helper.sh setup-localwp-domain plugin-testing plugin-testing.local

# Generate SSL certificate
./providers/localhost-helper.sh generate-cert plugin-testing.local
```

### **Docker Development**

- **Shared networks**: Use common network for all local containers
- **Traefik labels**: Standardize Traefik configuration
- **Volume management**: Consistent volume naming and paths
- **Environment variables**: Use `.env` files for configuration

### **Port Management**

- **WordPress sites**: 10000-10999 range
- **API services**: 8000-8999 range
- **MCP servers**: 8080+ range (sequential allocation)
- **Databases**: 5432 (PostgreSQL), 3306 (MySQL), 6379 (Redis)

## 🤖 **MCP Integration Best Practices**

### **Port Allocation**

```json
{
  "mcp_integration": {
    "base_port": 8081,
    "port_allocation": {
      "hostinger": 8080,
      "hetzner-main": 8081,
      "hetzner-client-project": 8082,
      "hetzner-storagebox": 8083,
      "closte": 8084
    }
  }
}
```

### **Service Organization**

- **Sequential ports**: Allocate ports sequentially starting from base
- **Service naming**: Use descriptive names matching account structure
- **Secure API storage**: Use secure local storage for API tokens (never in repository)
- **Health monitoring**: Monitor MCP server health and availability

## 📁 **File Organization**

### **Configuration Structure**

```text
~/
├── hetzner-config.json           # Hetzner API tokens
├── hostinger-config.json         # Hostinger site configurations
├── closte-config.json            # Closte server configurations
├── .ssh/
│   ├── hostinger_password        # Hostinger SSH password
│   ├── closte_password           # Closte SSH password
│   └── config                    # SSH client configuration
└── Local Sites/                  # LocalWP sites
    ├── plugin-testing/
    └── waas/
```

### **Git Repository Structure**

- **Helper scripts**: Root level for easy access
- **Configuration samples**: In `configs/` directory
- **Documentation**: In `docs/` directory
- **Provider scripts**: In `providers/` directory

## 🔍 **Monitoring & Maintenance**

### **Regular Tasks**

- **Weekly**: Check server status and resource usage
- **Monthly**: Review and rotate API tokens
- **Quarterly**: Audit SSH keys and access permissions
- **Annually**: Review and update security practices

### **Automation**

- **Health checks**: Automated server health monitoring
- **Backup verification**: Regular backup integrity checks
- **Certificate monitoring**: SSL certificate expiration alerts
- **Resource monitoring**: CPU, memory, and disk usage alerts

## 🎯 **AI Assistant Integration**

### **Context Documentation**

- **Infrastructure inventory**: Maintain current server/site lists
- **Access patterns**: Document common tasks and procedures
- **Security guidelines**: Clear security boundaries and requirements
- **Troubleshooting guides**: Common issues and solutions

### **Command Standardization**

- **Consistent interfaces**: Same command patterns across providers
- **Error handling**: Comprehensive error messages and recovery suggestions
- **Logging**: Detailed operation logs for audit and debugging
- **Help systems**: Built-in help and usage examples

---

**These practices are based on real production environments and have been proven to scale effectively while maintaining security and operational efficiency.**
