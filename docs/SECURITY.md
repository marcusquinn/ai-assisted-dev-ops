# Security Best Practices

This document outlines security best practices for the AI Assistant Server Access Framework.

## 🔐 **Credential Management**

### API Tokens

- **Never commit API tokens to version control**
- Store tokens in separate configuration files
- Add config files to `.gitignore`
- Use environment variables for CI/CD
- Rotate tokens regularly (quarterly recommended)
- Use least-privilege principle for API permissions

### SSH Keys

- **Use Ed25519 keys** (modern, secure, fast)
- Generate unique keys per environment if needed
- Protect private keys with passphrases
- Set proper file permissions (600 for private keys, 644 for public keys)
- Regular key rotation and audit

### Password Files

- Store SSH passwords in separate files (never in scripts)
- Set restrictive permissions (600)
- Consider using SSH keys instead of passwords when possible

## 🔑 **SSH Security**

### Key Management Best Practices

```bash
# Generate secure Ed25519 key
ssh-keygen -t ed25519 -C "your-email@domain.com"

# Set proper permissions
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Add passphrase protection
ssh-keygen -p -f ~/.ssh/id_ed25519
```

### SSH Configuration Security

```bash
# ~/.ssh/config security settings
Host *
    # Disable password authentication when keys are available
    PasswordAuthentication no

    # Use only secure key exchange algorithms
    KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group16-sha512

    # Use only secure ciphers
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com

    # Use only secure MAC algorithms
    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com

    # Disable X11 forwarding by default
    ForwardX11 no

    # Connection timeout
    ConnectTimeout 10
```

### Server Hardening

- Disable root login where possible
- Use non-standard SSH ports
- Implement fail2ban or similar
- Regular security updates
- Monitor SSH logs

## 🛡️ **Access Control**

### Principle of Least Privilege

- Grant minimum necessary permissions
- Use separate API tokens per project/environment
- Implement role-based access control
- Regular access reviews and cleanup

### Network Security

- Use VPNs or bastion hosts for sensitive environments
- Implement IP whitelisting where possible
- Use private networks for internal communication
- Monitor network traffic

### Multi-Factor Authentication

- Enable MFA on all cloud provider accounts
- Use hardware security keys when available
- Implement time-based OTP for API access

## 📊 **Monitoring and Auditing**

### Access Logging

```bash
# Enable SSH logging
# Add to /etc/ssh/sshd_config
LogLevel VERBOSE

# Monitor SSH access
tail -f /var/log/auth.log | grep ssh
```

### API Usage Monitoring

- Monitor API rate limits and usage
- Set up alerts for unusual activity
- Regular audit of API token usage
- Log all API calls in production

### Security Scanning

```bash
# Regular security scans
nmap -sS -O target-server

# SSH security audit
ssh-audit target-server

# SSL/TLS testing
testssl.sh target-server
```

## 🚨 **Incident Response**

### Compromise Detection

- Monitor for unauthorized SSH connections
- Watch for unusual API activity
- Set up alerts for failed authentication attempts
- Regular review of server logs

### Response Procedures

1. **Immediate Actions**
   - Disable compromised credentials
   - Block suspicious IP addresses
   - Isolate affected systems

2. **Investigation**
   - Analyze logs for attack vectors
   - Identify scope of compromise
   - Document findings

3. **Recovery**
   - Rotate all potentially compromised credentials
   - Update and patch systems
   - Restore from clean backups if necessary

4. **Prevention**
   - Implement additional security measures
   - Update security procedures
   - Conduct security training

## 🔒 **File Permissions**

### Recommended Permissions

```bash
# Configuration files
chmod 600 configs/.*.json

# SSH keys
chmod 600 ~/.ssh/id_*
chmod 644 ~/.ssh/id_*.pub
chmod 600 ~/.ssh/config
chmod 700 ~/.ssh/

# Password files
chmod 600 ~/.ssh/*_password

# Scripts
chmod 755 *.sh
chmod 755 providers/*.sh
chmod 755 ssh/*.sh
```

### Git Security

```bash
# .gitignore for security
echo "configs/.*.json" >> .gitignore
echo "*.password" >> .gitignore
echo ".env" >> .gitignore
echo "*.key" >> .gitignore
echo "*.pem" >> .gitignore
```

## 🌐 **Network Security**

### VPN and Bastion Hosts

- Use VPN for accessing production systems
- Implement bastion hosts for multi-hop access
- Restrict direct internet access to servers

### Firewall Rules

```bash
# Basic iptables rules
iptables -A INPUT -p tcp --dport 22 -s trusted-ip -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP
```

### SSL/TLS

- Use TLS 1.2 or higher for all API communications
- Implement certificate pinning where possible
- Regular certificate rotation

## 📋 **Security Checklist**

### Initial Setup

- [ ] Generate secure SSH keys with passphrases
- [ ] Set proper file permissions on all sensitive files
- [ ] Configure secure SSH client settings
- [ ] Add sensitive files to .gitignore
- [ ] Enable MFA on all cloud accounts

### Regular Maintenance

- [ ] Rotate API tokens quarterly
- [ ] Audit SSH keys and remove unused ones
- [ ] Review and update access permissions
- [ ] Monitor logs for suspicious activity
- [ ] Update and patch all systems

### Emergency Procedures

- [ ] Document incident response procedures
- [ ] Test backup and recovery processes
- [ ] Maintain emergency contact information
- [ ] Regular security drills and training

## 🔍 **Security Tools**

### Recommended Tools

```bash
# SSH security audit
ssh-audit server-ip

# Network scanning
nmap -sS -sV target

# SSL/TLS testing
testssl.sh target

# File integrity monitoring
aide --init
aide --check

# Log analysis
fail2ban-client status
```

### Automation

- Implement automated security scanning
- Set up log monitoring and alerting
- Use configuration management for consistent security settings
- Regular automated backups with encryption

---

**Remember: Security is an ongoing process, not a one-time setup. Regular reviews and updates are essential for maintaining a secure infrastructure.**
