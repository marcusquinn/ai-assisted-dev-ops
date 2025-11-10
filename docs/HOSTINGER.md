# Hostinger Provider Guide

Hostinger is a popular web hosting provider offering shared hosting, VPS, and cloud hosting solutions with competitive pricing and good performance.

## 🏢 **Provider Overview**

### **Hostinger Characteristics:**

- **Hosting Type**: Shared hosting, VPS, Cloud hosting
- **SSH Access**: Available on VPS and higher plans
- **Control Panel**: Custom hPanel (user-friendly)
- **SSH Authentication**: Password-based (SSH keys not supported on shared hosting)
- **API Support**: Limited API functionality
- **Pricing**: Budget-friendly with good value
- **Performance**: Good performance for the price point

### **Best Use Cases:**

- **Small to medium websites** with moderate traffic
- **WordPress hosting** with optimized performance
- **Development environments** for testing and staging
- **Cost-effective hosting** for multiple domains
- **Beginner-friendly** hosting with easy management

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/hostinger-config.json.txt configs/hostinger-config.json

# Edit with your actual server details
```

### **Configuration Structure:**

```json
{
  "sites": {
    "example.com": {
      "server": "server-hostname-or-ip",
      "port": 65002,
      "username": "u123456789",
      "password_file": "~/.ssh/hostinger_password",
      "domain_path": "/domains/example.com/public_html",
      "description": "Main website"
    }
  },
  "default_settings": {
    "port": 65002,
    "username_pattern": "u[0-9]+",
    "password_authentication": true,
    "ssh_keys_supported": false
  }
}
```

### **Password File Setup:**

```bash
# Create secure password file
echo 'your-hostinger-password' > ~/.ssh/hostinger_password
chmod 600 ~/.ssh/hostinger_password

# Install sshpass for password authentication
brew install sshpass  # macOS
sudo apt-get install sshpass  # Linux
```

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Hostinger sites
./providers/hostinger-helper.sh list

# Connect to a site
./providers/hostinger-helper.sh connect example.com

# Upload files to a site
./providers/hostinger-helper.sh upload example.com /local/path /remote/path

# Download files from a site
./providers/hostinger-helper.sh download example.com /remote/path /local/path

# Execute command on server
./providers/hostinger-helper.sh exec example.com 'ls -la'
```

### **File Management:**

```bash
# Upload website files
./providers/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/

# Backup website
./providers/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backup/

# Update specific files
./providers/hostinger-helper.sh upload example.com ./index.html /domains/example.com/public_html/index.html
```

### **Database Operations:**

```bash
# Access MySQL (if available)
./providers/hostinger-helper.sh exec example.com 'mysql -u username -p database_name'

# Backup database
./providers/hostinger-helper.sh exec example.com 'mysqldump -u username -p database_name > backup.sql'
```

## 🛡️ **Security Considerations**

### **Password Security:**

- **Secure storage**: Store passwords in files with 600 permissions
- **Never commit**: Add password files to .gitignore
- **Regular rotation**: Change passwords periodically
- **Strong passwords**: Use complex, unique passwords

### **SSH Security:**

- **Non-standard port**: Hostinger uses port 65002
- **Password authentication**: SSH keys not supported on shared hosting
- **Connection limits**: Be aware of concurrent connection limits
- **IP restrictions**: Consider IP-based access restrictions if available

### **File Permissions:**

```bash
# Set proper permissions for web files
./providers/hostinger-helper.sh exec example.com 'chmod 644 /domains/example.com/public_html/*.html'
./providers/hostinger-helper.sh exec example.com 'chmod 755 /domains/example.com/public_html/scripts/'
```

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Connection Refused:**

```bash
# Check if SSH is enabled on your plan
# Verify server hostname and port (usually 65002)
# Ensure password is correct
```

#### **Permission Denied:**

```bash
# Verify username format (usually u followed by numbers)
# Check password file permissions (should be 600)
# Ensure sshpass is installed
```

#### **File Upload Issues:**

```bash
# Check destination path exists
./providers/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/'

# Verify disk space
./providers/hostinger-helper.sh exec example.com 'df -h'

# Check file permissions
./providers/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/public_html/'
```

## 📊 **Performance Optimization**

### **Website Performance:**

```bash
# Enable compression (if supported)
./providers/hostinger-helper.sh exec example.com 'echo "gzip on;" >> /domains/example.com/.htaccess'

# Optimize images before upload
# Use tools like imagemin or tinypng before uploading

# Monitor resource usage
./providers/hostinger-helper.sh exec example.com 'top'
./providers/hostinger-helper.sh exec example.com 'df -h'
```

### **Caching Strategies:**

- **Browser caching**: Configure .htaccess for static assets
- **CDN integration**: Use Cloudflare or similar CDN
- **Image optimization**: Compress images before upload
- **Minification**: Minify CSS/JS before deployment

## 🔄 **Backup & Deployment**

### **Automated Backups:**

```bash
# Create backup script
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
./providers/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backups/example.com_$DATE/
```

### **Deployment Workflow:**

```bash
# Build and deploy
npm run build
./providers/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/

# Verify deployment
./providers/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/public_html/'
```

## 📚 **Best Practices**

### **Development Workflow:**

1. **Local development**: Develop and test locally first
2. **Staging environment**: Use subdomain for staging
3. **Backup before deploy**: Always backup before major changes
4. **Incremental updates**: Upload only changed files when possible
5. **Monitor performance**: Check site performance after deployments

### **File Organization:**

- **Consistent structure**: Maintain consistent directory structure
- **Version control**: Use Git for source code management
- **Documentation**: Document deployment procedures
- **Environment configs**: Separate configs for different environments

### **Monitoring:**

- **Uptime monitoring**: Use services like UptimeRobot
- **Performance monitoring**: Monitor page load times
- **Error logging**: Check server logs regularly
- **Resource usage**: Monitor disk space and bandwidth

## 🎯 **AI Assistant Integration**

### **Automated Tasks:**

- **Deployment automation**: Automated file uploads after builds
- **Backup scheduling**: Regular automated backups
- **Performance monitoring**: Automated performance checks
- **Security scanning**: Regular security audits
- **Content updates**: Automated content deployment

### **Monitoring & Alerts:**

- **Uptime alerts**: Notifications for site downtime
- **Performance alerts**: Warnings for slow performance
- **Security alerts**: Notifications for security issues
- **Resource alerts**: Warnings for high resource usage

---

**Hostinger provides excellent value for money with good performance, making it ideal for small to medium websites and development environments.** 🚀
