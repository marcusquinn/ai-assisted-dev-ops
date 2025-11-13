# WordPress Performance Optimization Workflow

This template provides a comprehensive workflow for optimizing WordPress website performance using the AI DevOps framework.

## 🚀 **Quick Performance Audit**

```bash
# Comprehensive WordPress performance analysis
./providers/pagespeed-helper.sh wordpress https://your-wordpress-site.com

# This will run:
# 1. PageSpeed Insights (desktop & mobile)
# 2. Lighthouse comprehensive audit
# 3. WordPress-specific recommendations
```

## 📊 **Step-by-Step Optimization Process**

### **1. Initial Performance Baseline**

```bash
# Create baseline report
./providers/pagespeed-helper.sh audit https://your-site.com
```

**Key Metrics to Track:**

- Performance Score (target: >90%)
- First Contentful Paint (target: <1.8s)
- Largest Contentful Paint (target: <2.5s)
- Cumulative Layout Shift (target: <0.1)

### **2. WordPress-Specific Optimizations**

#### **Plugin Performance**
```bash
# Use Query Monitor plugin to identify slow plugins
# Disable unnecessary plugins
# Replace heavy plugins with lightweight alternatives
```

#### **Image Optimization**
```bash
# Convert images to WebP format
# Implement lazy loading
# Use proper image dimensions
# Consider CDN for image delivery
```

#### **Caching Implementation**
```bash
# Install caching plugin (WP Rocket recommended)
# Configure page caching
# Enable object caching (Redis/Memcached)
# Set up CDN integration
```

#### **Database Optimization**
```bash
# Clean up post revisions
# Remove spam comments
# Optimize database tables
# Use WP-Optimize or similar plugin
```

### **3. Server-Level Optimizations**

```bash
# Check server response time (TTFB)
# Ensure adequate server resources
# Consider upgrading hosting if needed
# Implement server-level caching
```

### **4. Code Optimizations**

```bash
# Minify CSS and JavaScript
# Remove unused CSS/JS
# Optimize critical rendering path
# Use lightweight theme
```

## 🔄 **Continuous Monitoring Workflow**

### **Weekly Performance Check**

```bash
# Create monitoring script
cat > weekly-performance-check.sh << 'EOF'
#!/bin/bash
SITE_URL="https://your-wordpress-site.com"
DATE=$(date +"%Y-%m-%d")

echo "Weekly Performance Check - $DATE"
./providers/pagespeed-helper.sh wordpress "$SITE_URL"

# Save results for comparison
cp ~/.ai-devops/reports/pagespeed/lighthouse_*.json "weekly-reports/lighthouse-$DATE.json"
EOF

chmod +x weekly-performance-check.sh
```

### **Automated Monitoring with Cron**

```bash
# Add to crontab for weekly monitoring
# 0 9 * * 1 /path/to/weekly-performance-check.sh
```

## 🎯 **AI Assistant Integration**

### **System Prompt for WordPress Optimization**

Add this to your AI assistant's system prompt:

```
For WordPress performance optimization, use the PageSpeed and Lighthouse tools in 
~/git/aidevops/providers/pagespeed-helper.sh. Focus on:

1. Core Web Vitals improvement
2. WordPress-specific optimizations (plugins, themes, caching)
3. Image optimization and CDN implementation
4. Database cleanup and optimization
5. Server-level performance enhancements

Always provide specific, actionable recommendations with implementation steps.
```

### **Common AI Assistant Tasks**

1. **"Audit my WordPress site performance"**
   ```bash
   ./providers/pagespeed-helper.sh wordpress https://your-site.com
   ```

2. **"Compare performance before and after optimization"**
   ```bash
   ./providers/pagespeed-helper.sh report before-optimization.json
   ./providers/pagespeed-helper.sh report after-optimization.json
   ```

3. **"Monitor multiple WordPress sites"**
   ```bash
   # Create sites list
   echo "https://site1.com" > wordpress-sites.txt
   echo "https://site2.com" >> wordpress-sites.txt
   
   ./providers/pagespeed-helper.sh bulk wordpress-sites.txt
   ```

## 📈 **Performance Targets**

### **Core Web Vitals Goals**

- **First Contentful Paint (FCP)**: < 1.8 seconds
- **Largest Contentful Paint (LCP)**: < 2.5 seconds
- **First Input Delay (FID)**: < 100 milliseconds
- **Cumulative Layout Shift (CLS)**: < 0.1

### **Lighthouse Scores**

- **Performance**: > 90%
- **Accessibility**: > 95%
- **Best Practices**: > 90%
- **SEO**: > 90%

## 🛠️ **Common WordPress Performance Issues & Solutions**

### **Slow Loading Times**

- **Issue**: Large images, unoptimized plugins
- **Solution**: Image optimization, plugin audit, caching

### **Poor Mobile Performance**

- **Issue**: Unresponsive design, large resources
- **Solution**: Mobile-first optimization, AMP implementation

### **High Server Response Time**

- **Issue**: Inadequate hosting, database issues
- **Solution**: Hosting upgrade, database optimization

### **Layout Shifts**

- **Issue**: Images without dimensions, dynamic content
- **Solution**: Specify image dimensions, optimize loading sequence

## 📊 **Reporting and Analysis**

### **Generate Performance Report**

```bash
# Generate comprehensive report
./providers/pagespeed-helper.sh lighthouse https://your-site.com json
./providers/pagespeed-helper.sh report ~/.ai-devops/reports/pagespeed/lighthouse_*.json
```

### **Track Improvements Over Time**

```bash
# Compare reports
echo "Performance improvement tracking:"
echo "Before: $(jq '.categories.performance.score' before.json)"
echo "After: $(jq '.categories.performance.score' after.json)"
```

This workflow ensures systematic WordPress performance optimization with measurable results and continuous monitoring.
