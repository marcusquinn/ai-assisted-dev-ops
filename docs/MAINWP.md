# MainWP WordPress Management Guide

MainWP is a powerful self-hosted WordPress management platform that allows you to manage multiple WordPress sites from a single dashboard with comprehensive API access.

## 🏢 **Provider Overview**

### **MainWP Characteristics:**

- **Service Type**: Self-hosted WordPress management platform
- **Architecture**: Central dashboard managing multiple WordPress sites
- **API Support**: Comprehensive REST API for automation
- **Scalability**: Manage unlimited WordPress sites
- **Security**: Built-in security scanning and monitoring
- **Backup Management**: Automated backup scheduling and management
- **Update Management**: Centralized WordPress, plugin, and theme updates

### **Best Use Cases:**

- **WordPress agencies** managing multiple client sites
- **Large organizations** with multiple WordPress properties
- **Developers** managing staging and production environments
- **Automated WordPress maintenance** and monitoring
- **Centralized security management** across WordPress sites
- **Bulk operations** on multiple WordPress installations

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/mainwp-config.json.txt configs/mainwp-config.json

# Edit with your actual MainWP instance details
```

### **Multi-Instance Configuration:**

```json
{
  "instances": {
    "production": {
      "base_url": "https://mainwp.yourdomain.com",
      "consumer_key": "YOUR_MAINWP_CONSUMER_KEY_HERE",
      "consumer_secret": "YOUR_MAINWP_CONSUMER_SECRET_HERE",
      "description": "Production MainWP instance",
      "managed_sites_count": 25
    },
    "staging": {
      "base_url": "https://staging-mainwp.yourdomain.com",
      "consumer_key": "YOUR_STAGING_MAINWP_CONSUMER_KEY_HERE",
      "consumer_secret": "YOUR_STAGING_MAINWP_CONSUMER_SECRET_HERE",
      "description": "Staging MainWP instance",
      "managed_sites_count": 5
    }
  }
}
```

### **API Credentials Setup:**

1. **Install MainWP Dashboard** on your server
2. **Install MainWP REST API Extension**
3. **Generate API credentials** in MainWP Dashboard
4. **Configure child sites** with MainWP Child plugin
5. **Test API access** with the helper script

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all MainWP instances
./providers/mainwp-helper.sh instances

# List all managed sites
./providers/mainwp-helper.sh sites production

# Get site details
./providers/mainwp-helper.sh site-details production 123

# Monitor all sites
./providers/mainwp-helper.sh monitor production
```

### **WordPress Management:**

```bash
# Update WordPress core for a site
./providers/mainwp-helper.sh update-core production 123

# Update all plugins for a site
./providers/mainwp-helper.sh update-plugins production 123

# Update specific plugin
./providers/mainwp-helper.sh update-plugin production 123 akismet

# List site plugins
./providers/mainwp-helper.sh plugins production 123

# List site themes
./providers/mainwp-helper.sh themes production 123
```

### **Backup Management:**

```bash
# Create full backup
./providers/mainwp-helper.sh backup production 123 full

# Create database backup
./providers/mainwp-helper.sh backup production 123 db

# Create files backup
./providers/mainwp-helper.sh backup production 123 files

# List all backups
./providers/mainwp-helper.sh backups production 123
```

### **Security Management:**

```bash
# Run security scan
./providers/mainwp-helper.sh security-scan production 123

# Get security scan results
./providers/mainwp-helper.sh security-results production 123

# Comprehensive security audit
./providers/mainwp-helper.sh audit-security production 123

# Get uptime status
./providers/mainwp-helper.sh uptime production 123
```

### **Bulk Operations:**

```bash
# Bulk WordPress core updates
./providers/mainwp-helper.sh bulk-update-wp production 123 124 125

# Bulk plugin updates
./providers/mainwp-helper.sh bulk-update-plugins production 123 124 125

# Sync multiple sites
for site_id in 123 124 125; do
    ./providers/mainwp-helper.sh sync production $site_id
done
```

### **Site Monitoring:**

```bash
# Get site status
./providers/mainwp-helper.sh site-status production 123

# Sync site data
./providers/mainwp-helper.sh sync production 123

# Monitor all sites overview
./providers/mainwp-helper.sh monitor production
```

## 🛡️ **Security Best Practices**

### **API Security:**

- **Secure credentials**: Store API credentials securely
- **HTTPS only**: Always use HTTPS for MainWP instances
- **Regular rotation**: Rotate API credentials regularly
- **Access control**: Limit API access to trusted systems
- **Rate limiting**: Implement appropriate rate limiting

### **MainWP Instance Security:**

```bash
# Regular security audits
./providers/mainwp-helper.sh audit-security production 123

# Monitor security scan results
./providers/mainwp-helper.sh security-results production 123

# Check uptime and availability
./providers/mainwp-helper.sh uptime production 123
```

### **WordPress Security:**

- **Regular updates**: Keep WordPress core, plugins, and themes updated
- **Security scanning**: Run regular security scans on all sites
- **Backup verification**: Verify backup integrity regularly
- **Access monitoring**: Monitor login attempts and access patterns
- **SSL certificates**: Ensure all sites have valid SSL certificates

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **API Connection Errors:**

```bash
# Verify API credentials
./providers/mainwp-helper.sh instances

# Check MainWP instance accessibility
curl -I https://mainwp.yourdomain.com/wp-json/mainwp/v1/

# Verify SSL certificate
openssl s_client -connect mainwp.yourdomain.com:443
```

#### **Site Sync Issues:**

```bash
# Force site sync
./providers/mainwp-helper.sh sync production 123

# Check site status
./providers/mainwp-helper.sh site-status production 123

# Verify child plugin is active on target site
```

#### **Update Failures:**

```bash
# Check site details for error messages
./providers/mainwp-helper.sh site-details production 123

# Verify site accessibility
./providers/mainwp-helper.sh uptime production 123

# Check for maintenance mode or plugin conflicts
```

## 📊 **Monitoring & Analytics**

### **Site Health Monitoring:**

```bash
# Daily monitoring routine
./providers/mainwp-helper.sh monitor production

# Check for sites needing updates
./providers/mainwp-helper.sh monitor production | grep "updates available"

# Security status overview
for site_id in $(./providers/mainwp-helper.sh sites production | awk '{print $1}' | grep -E '^[0-9]+$'); do
    ./providers/mainwp-helper.sh security-results production $site_id
done
```

### **Automated Monitoring:**

```bash
# Create monitoring script
#!/bin/bash
INSTANCE="production"

# Get sites needing attention
echo "=== SITES NEEDING UPDATES ==="
./providers/mainwp-helper.sh monitor $INSTANCE

echo "=== BACKUP STATUS ==="
for site_id in $(./providers/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Site $site_id backups:"
    ./providers/mainwp-helper.sh backups $INSTANCE $site_id | tail -5
done

echo "=== SECURITY ALERTS ==="
for site_id in $(./providers/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    security_results=$(./providers/mainwp-helper.sh security-results $INSTANCE $site_id)
    if echo "$security_results" | grep -q "warning\|error\|critical"; then
        echo "Site $site_id has security issues:"
        echo "$security_results"
    fi
done
```

### **Performance Tracking:**

- **Update success rates**: Track successful vs failed updates
- **Backup completion**: Monitor backup success rates
- **Site uptime**: Track site availability and performance
- **Security scan results**: Monitor security scan outcomes
- **Response times**: Track API response times and site performance

## 🔄 **Backup & Disaster Recovery**

### **Backup Strategies:**

```bash
# Daily backup routine
#!/bin/bash
INSTANCE="production"

for site_id in $(./providers/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Creating backup for site $site_id"
    ./providers/mainwp-helper.sh backup $INSTANCE $site_id full
    sleep 30  # Rate limiting
done
```

### **Backup Verification:**

```bash
# Verify recent backups
for site_id in $(./providers/mainwp-helper.sh sites production | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Backup status for site $site_id:"
    ./providers/mainwp-helper.sh backups production $site_id | head -3
done
```

## 📚 **Best Practices**

### **WordPress Management:**

1. **Staged updates**: Test updates on staging before production
2. **Regular backups**: Maintain regular backup schedules
3. **Security monitoring**: Run regular security scans
4. **Performance monitoring**: Monitor site performance and uptime
5. **Documentation**: Document all maintenance procedures

### **Automation Strategies:**

- **Scheduled maintenance**: Automate routine maintenance tasks
- **Update workflows**: Implement staged update procedures
- **Backup verification**: Automate backup integrity checks
- **Security monitoring**: Automate security scan scheduling
- **Alert integration**: Integrate with monitoring and alerting systems

### **Multi-Site Management:**

- **Site categorization**: Organize sites by type and criticality
- **Update policies**: Implement different update policies per site type
- **Backup strategies**: Tailor backup frequency to site importance
- **Security levels**: Apply appropriate security measures per site
- **Access control**: Implement role-based access control

## 🎯 **AI Assistant Integration**

### **Automated WordPress Management:**

- **Update orchestration**: Automated WordPress, plugin, and theme updates
- **Backup management**: Automated backup scheduling and verification
- **Security monitoring**: Automated security scanning and threat detection
- **Performance optimization**: Automated performance monitoring and optimization
- **Issue resolution**: Automated detection and resolution of common issues

### **Intelligent Operations:**

- **Predictive maintenance**: AI-driven maintenance scheduling
- **Anomaly detection**: Automated detection of unusual site behavior
- **Performance analysis**: Automated performance analysis and recommendations
- **Security assessment**: Automated security posture assessment
- **Capacity planning**: Automated resource usage analysis and planning

---

**MainWP provides comprehensive WordPress management capabilities with powerful API access, making it ideal for automated WordPress site management at scale.** 🚀
