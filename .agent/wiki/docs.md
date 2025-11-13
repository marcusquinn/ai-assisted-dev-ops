# Documentation AI Context

This folder contains comprehensive documentation for all services and components in the AI DevOps Framework.

## 📚 **Documentation Categories**

### **Service-Specific Guides**

Each service has a comprehensive guide following the standard structure:

**Infrastructure & Hosting:**

- `HOSTINGER.md` - Shared hosting management
- `HETZNER.md` - Cloud VPS management
- `CLOSTE.md` - VPS hosting management
- `CLOUDRON.md` - App platform management

**Deployment & Content:**

- `COOLIFY.md` - Self-hosted PaaS deployment
- `MAINWP.md` - WordPress management platform

**Security & Quality:**

- `VAULTWARDEN.md` - Password and secrets management
- `CODE-AUDITING.md` - Multi-platform code quality analysis

**Version Control & Domains:**

- `GIT-PLATFORMS.md` - GitHub, GitLab, Gitea management
- `DOMAIN-PURCHASING.md` - Automated domain purchasing
- `SPACESHIP.md` - Spaceship domain registrar
- `101DOMAINS.md` - 101domains registrar

**Email & DNS:**

- `SES.md` - Amazon SES email delivery
- `DNS-PROVIDERS.md` - Multi-provider DNS management

**Development & Local:**

- `LOCALHOST.md` - Local development environments
- `LOCALWP-MCP.md` - LocalWP MCP integration
- `MCP-SERVERS.md` - MCP server configuration
- `CONTEXT7-MCP-SETUP.md` - Context7 MCP setup

### **Framework Guides**

- `BEST-PRACTICES.md` - Provider selection and best practices
- `CLOUDFLARE-SETUP.md` - Cloudflare API setup guide
- `COOLIFY-SETUP.md` - Coolify deployment setup

## 📖 **Standard Documentation Structure**

Each service guide follows this consistent format:

```markdown
# [Service Name] Guide

## 🏢 **Provider Overview**
### **[Service] Characteristics:**
- Service type, strengths, API support, use cases

## 🔧 **Configuration**
- Setup instructions and configuration examples

## 🚀 **Usage Examples**
- Command examples and common operations

## 🛡️ **Security Best Practices**
- Security guidelines and recommendations

## 🔍 **Troubleshooting**
- Common issues and solutions

## 📊 **MCP Integration** (if applicable)
- MCP server setup and capabilities

## 📚 **Best Practices**
- Service-specific best practices

## 🎯 **AI Assistant Integration**
- AI automation capabilities and patterns
```

## 🎯 **Documentation Standards**

### **Content Requirements**

1. **Complete coverage** of all service features
2. **Real working examples** with actual commands
3. **Security considerations** for each service
4. **Troubleshooting guidance** for common issues
5. **AI assistant integration** patterns and capabilities

### **Writing Standards**

1. **Clear, concise language** suitable for technical users
2. **Consistent formatting** across all documents
3. **Code examples** with proper syntax highlighting
4. **Visual hierarchy** with appropriate headers and sections
5. **Cross-references** to related services and guides

### **Technical Standards**

1. **Accurate command syntax** and parameters
2. **Current API information** and endpoints
3. **Working configuration examples** (sanitized)
4. **Proper security guidance** and warnings
5. **Version-aware information** where applicable

## 🔄 **Documentation Maintenance**

### **Regular Updates**

- **Service API changes** - Update when services change APIs
- **New features** - Document new service features and capabilities
- **Security updates** - Update security recommendations
- **Best practices** - Evolve best practices based on experience
- **AI capabilities** - Update AI integration patterns

### **Quality Assurance**

- **Technical accuracy** - Verify all commands and examples work
- **Completeness** - Ensure all service features are documented
- **Consistency** - Maintain consistent structure and formatting
- **Clarity** - Ensure documentation is clear and understandable
- **Currency** - Keep information current and relevant

## 🤖 **AI Assistant Usage Guidelines**

### **Documentation Navigation**

- **Use service-specific guides** for detailed service information
- **Reference BEST-PRACTICES.md** for provider selection guidance
- **Check setup guides** for complex integrations
- **Use Context7 MCP** for latest service documentation when available

### **Information Hierarchy**

1. **Service-specific guides** - Primary source for service details
2. **Framework context** (`../ai-context.md`) - Overall framework understanding
3. **Best practices guide** - Provider selection and optimization
4. **Setup guides** - Complex integration procedures
5. **Context7 MCP** - Latest external documentation

### **Documentation Patterns**

- **Start with service guide** for comprehensive understanding
- **Use examples section** for practical implementation
- **Check troubleshooting** for common issues
- **Reference security section** for security considerations
- **Use AI integration section** for automation patterns

## 📊 **Cross-Service Integration**

### **Related Services**

Many services work together in common workflows:

**Domain → DNS → Hosting:**

- Domain purchasing (Spaceship/101domains)
- DNS configuration (Cloudflare/Route53)
- Hosting setup (Hetzner/Hostinger)

**Development → Quality → Deployment:**

- Git platforms (GitHub/GitLab)
- Code auditing (CodeRabbit/SonarCloud)
- Deployment (Coolify/hosting providers)

**Security → Credentials → Monitoring:**

- Vaultwarden (credential management)
- Email monitoring (SES)
- Security auditing (code audit services)

### **Workflow Documentation**

Each service guide includes:

- **Integration examples** with other services
- **Workflow patterns** for common use cases
- **Cross-service dependencies** and requirements
- **Combined operations** examples

## 🔍 **Finding Information**

### **Quick Reference**

```bash
# Service-specific information
docs/[SERVICE-NAME].md

# Framework overview
../ai-context.md

# Provider selection guidance
docs/BEST-PRACTICES.md

# Setup procedures
docs/[SERVICE]-SETUP.md
```

### **Search Patterns**

- **Service capabilities**: Check service-specific guide
- **Configuration help**: Check service guide + config templates
- **Integration patterns**: Check service guide + best practices
- **Troubleshooting**: Check service guide troubleshooting section
- **Security guidance**: Check service guide security section

---

**All documentation is designed to provide comprehensive, accurate, and actionable information for both human users and AI assistants managing the DevOps framework.** 📚🤖
