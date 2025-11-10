# Coolify Setup Guide

Coolify is a self-hosted alternative to Vercel, Netlify, and Heroku that allows you to deploy applications with ease using Docker containers.

## 🚀 **What is Coolify?**

Coolify is an open-source, self-hostable cloud platform that:

- **Deploys applications** from Git repositories automatically
- **Manages databases** (PostgreSQL, MySQL, MongoDB, Redis, etc.)
- **Handles SSL certificates** automatically via Let's Encrypt
- **Provides monitoring** and logging for your applications
- **Supports multiple languages** (Node.js, Python, PHP, Go, Rust, static sites)
- **Uses Docker** for containerization and isolation

## 📋 **Prerequisites**

### **Server Requirements:**

- **VPS or dedicated server** with at least 2GB RAM (4GB+ recommended)
- **Ubuntu 20.04+ or Debian 11+** (recommended)
- **Root access** or sudo privileges
- **Domain name** pointing to your server
- **Open ports**: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8000 (Coolify dashboard)

### **Local Requirements:**

- **SSH key** for server access
- **Git repositories** for your applications
- **Domain DNS** configured to point to your server

## 🛠️ **Installation**

### **1. Server Setup**

#### **Install Coolify:**

```bash
# Connect to your server
ssh root@your-server-ip

# Install Coolify (one-line installer)
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

#### **Post-Installation:**

```bash
# Check Coolify status
systemctl status coolify

# View Coolify logs
docker logs coolify

# Access Coolify dashboard
# Open: https://your-server-ip:8000
```

### **2. Initial Configuration**

#### **Access Web Interface:**

1. **Open browser**: `https://your-server-ip:8000`
2. **Create admin account**: Set username and password
3. **Configure server**: Add your server details
4. **Setup domain**: Configure your domain name
5. **Generate SSH keys**: For Git repository access

#### **Security Setup:**

```bash
# Configure firewall (if using ufw)
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8000/tcp
ufw enable

# Update system packages
apt update && apt upgrade -y

# Setup automatic security updates
apt install unattended-upgrades -y
dpkg-reconfigure -plow unattended-upgrades
```

## 🔧 **Framework Configuration**

### **1. Copy Configuration Template:**

```bash
cp configs/coolify-config.json.txt configs/coolify-config.json
```

### **2. Edit Configuration:**

```json
{
  "servers": {
    "coolify-main": {
      "name": "Main Coolify Server",
      "host": "coolify.yourdomain.com",
      "ip": "your-server-ip",
      "coolify_url": "https://coolify.yourdomain.com",
      "ssh_key": "~/.ssh/id_ed25519"
    }
  },
  "api_configuration": {
    "main_server": {
      "api_token": "your-coolify-api-token",
      "base_url": "https://coolify.yourdomain.com/api/v1"
    }
  }
}
```

### **3. Generate API Token:**

1. **Login to Coolify dashboard**
2. **Go to Settings** → API Tokens
3. **Create new token** with required permissions
4. **Copy token** to your configuration file

## 🚀 **Deploying Your First Application**

### **1. Static Site (React/Vue/Angular):**

```bash
# In Coolify dashboard:
# 1. Create new application
# 2. Connect Git repository
# 3. Set build command: npm run build
# 4. Set output directory: dist (or build)
# 5. Configure domain name
# 6. Deploy!
```

### **2. Node.js Application:**

```bash
# In Coolify dashboard:
# 1. Create new application
# 2. Connect Git repository
# 3. Set start command: npm start
# 4. Configure environment variables
# 5. Set port (usually 3000)
# 6. Configure domain name
# 7. Deploy!
```

### **3. Database Setup:**

```bash
# In Coolify dashboard:
# 1. Go to Databases
# 2. Create new database (PostgreSQL/MySQL/MongoDB/Redis)
# 3. Configure database name and credentials
# 4. Connect to your application via environment variables
```

## 🔧 **Using the Framework Helper**

### **Server Management:**

```bash
# List Coolify servers
./providers/coolify-helper.sh list

# Connect to server via SSH
./providers/coolify-helper.sh connect coolify-main

# Open Coolify web interface
./providers/coolify-helper.sh open coolify-main

# Check server status
./providers/coolify-helper.sh status coolify-main
```

### **Application Management:**

```bash
# List applications on server
./providers/coolify-helper.sh apps main_server

# Execute commands on server
./providers/coolify-helper.sh exec coolify-main 'docker ps'
./providers/coolify-helper.sh exec coolify-main 'df -h'
```

### **SSH Configuration:**

```bash
# Generate SSH configs for easy access
./providers/coolify-helper.sh generate-ssh-configs

# Then you can simply use:
ssh coolify-main
```

## 🛡️ **Security Best Practices**

### **Server Security:**

- **Use SSH keys** instead of passwords
- **Configure firewall** to allow only necessary ports
- **Enable automatic security updates**
- **Regular backups** of applications and databases
- **Monitor server resources** and logs

### **Application Security:**

- **Use environment variables** for sensitive configuration
- **Enable HTTPS** for all applications (automatic with Coolify)
- **Regular updates** of application dependencies
- **Implement proper logging** and monitoring
- **Use strong database passwords**

### **Access Control:**

- **Limit SSH access** to specific IP addresses
- **Use strong passwords** for Coolify dashboard
- **Regular API token rotation**
- **Monitor access logs** for suspicious activity

## 🔍 **Monitoring & Maintenance**

### **Health Checks:**

```bash
# Check Coolify service status
./providers/coolify-helper.sh exec coolify-main 'systemctl status coolify'

# Check Docker containers
./providers/coolify-helper.sh exec coolify-main 'docker ps'

# Check disk space
./providers/coolify-helper.sh exec coolify-main 'df -h'

# Check memory usage
./providers/coolify-helper.sh exec coolify-main 'free -h'
```

### **Log Management:**

```bash
# View Coolify logs
./providers/coolify-helper.sh exec coolify-main 'docker logs coolify'

# View application logs (in Coolify dashboard)
# Go to Application → Logs tab

# System logs
./providers/coolify-helper.sh exec coolify-main 'journalctl -u coolify -f'
```

### **Backup Strategy:**

- **Database backups**: Configure automatic backups in Coolify
- **Application code**: Stored in Git repositories
- **Server snapshots**: Regular VPS/server snapshots
- **Configuration backups**: Backup Coolify configuration

## 🚨 **Troubleshooting**

### **Common Issues:**

#### **Deployment Fails:**

```bash
# Check build logs in Coolify dashboard
# Verify build commands and dependencies
# Check environment variables
# Ensure sufficient disk space and memory
```

#### **SSL Certificate Issues:**

```bash
# Verify domain DNS points to server
# Check firewall allows ports 80 and 443
# Ensure domain is properly configured in Coolify
# Check Let's Encrypt rate limits
```

#### **Application Not Accessible:**

```bash
# Check application logs in Coolify dashboard
# Verify port configuration
# Check health check endpoints
# Ensure application is running (docker ps)
```

#### **Database Connection Issues:**

```bash
# Verify database is running
# Check connection strings and credentials
# Ensure network connectivity between containers
# Check database logs
```

## 📚 **Additional Resources**

- **Official Documentation**: https://coolify.io/docs
- **GitHub Repository**: https://github.com/coollabsio/coolify
- **Community Discord**: https://discord.gg/coolify
- **Video Tutorials**: Available on YouTube
- **Example Applications**: https://github.com/coollabsio/coolify-examples

## 🎯 **Benefits for AI-Assisted Development**

- **Automated deployments** from Git pushes
- **Environment management** for different stages
- **Database provisioning** with one click
- **SSL certificate automation**
- **Container orchestration** without complexity
- **Monitoring and logging** built-in
- **Cost-effective** compared to cloud platforms
- **Full control** over your infrastructure

---

**Coolify provides a powerful, self-hosted alternative to expensive cloud platforms while maintaining simplicity and automation!** 🚀
