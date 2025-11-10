# LocalWP MCP Integration Guide

This guide explains how to set up and use the LocalWP MCP server for AI-powered WordPress database access.

## 🎯 **What is LocalWP MCP?**

LocalWP MCP is a Model Context Protocol server that gives AI assistants like Claude and Cursor direct, read-only access to your Local by Flywheel WordPress databases. Instead of guessing table structures or writing SQL queries blind, your AI can now see and understand your actual WordPress data.

## 🚀 **Why This Changes Everything**

### **Before MCP (AI Flying Blind)**

```sql
-- AI guesses at table structure
SELECT post_id, activity_meta FROM wp_user_activity
WHERE user_id=123 AND activity_type='quiz';
-- ❌ Error: activity_meta column doesn't exist!
```

### **After MCP (AI With X-Ray Vision)**

```sql
-- AI sees actual table structure and relationships
SELECT ua.post_id, ua.activity_id, uam.activity_meta_key, uam.activity_meta_value
FROM wp_user_activity ua
LEFT JOIN wp_user_activity_meta uam ON ua.activity_id = uam.activity_id
WHERE ua.user_id=123 AND ua.activity_type='quiz';
-- ✅ Perfect query on first try!
```

## 📦 **Installation**

### **Prerequisites**

- Local by Flywheel installed and running
- Node.js 18+ installed
- At least one active Local site

### **Install LocalWP MCP Server**

```bash
# Global installation (recommended)
npm install -g @verygoodplugins/mcp-local-wp

# Verify installation
mcp-local-wp --help
```

## 🔧 **Configuration**

### **1. Add to MCP Configuration**

**For Claude Desktop:**

```json
{
  "mcpServers": {
    "localwp": {
      "command": "mcp-local-wp",
      "args": ["--transport", "sse", "--port", "8085"],
      "env": {
        "DEBUG": "false"
      }
    }
  }
}
```

**For Cursor IDE:**

```json
{
  "mcpServers": {
    "localwp": {
      "command": "mcp-local-wp",
      "args": ["--transport", "sse", "--port", "8085"]
    }
  }
}
```

### **2. Using the Framework Helper**

```bash
# Start LocalWP MCP server
./providers/localhost-helper.sh start-mcp

# Stop LocalWP MCP server
./providers/localhost-helper.sh stop-mcp

# Check LocalWP sites
./providers/localhost-helper.sh list-localwp
```

## 🛠️ **Available Tools**

### **mysql_query**

Execute read-only SQL queries against your WordPress database.

**Supported Operations:**

- `SELECT` - Query data
- `SHOW` - Show tables, columns, etc.
- `DESCRIBE` - Describe table structure
- `EXPLAIN` - Explain query execution

**Examples:**

```sql
-- Get recent posts
SELECT ID, post_title, post_date, post_status
FROM wp_posts
WHERE post_type = 'post' AND post_status = 'publish'
ORDER BY post_date DESC LIMIT 5;

-- Parameterized queries
SELECT * FROM wp_posts WHERE post_status = ? ORDER BY post_date DESC LIMIT ?;
-- params: ["publish", "5"]
```

### **mysql_schema**

Inspect database schema and structure.

**Usage:**

```bash
# List all tables
mysql_schema()

# Inspect specific table
mysql_schema("wp_posts")
```

## 🎯 **Real-World Use Cases**

### **1. Plugin Development**

```sql
-- Understand LearnDash table structure
DESCRIBE wp_learndash_user_activity;

-- Find quiz completion data
SELECT ua.*, uam.activity_meta_key, uam.activity_meta_value
FROM wp_learndash_user_activity ua
LEFT JOIN wp_learndash_user_activity_meta uam ON ua.activity_id = uam.activity_id
WHERE ua.activity_type = 'quiz' AND ua.user_id = 123;
```

### **2. WooCommerce Analysis**

```sql
-- Get order data with meta
SELECT p.ID, p.post_date, pm.meta_key, pm.meta_value
FROM wp_posts p
JOIN wp_postmeta pm ON p.ID = pm.post_id
WHERE p.post_type = 'shop_order'
AND pm.meta_key IN ('_order_total', '_billing_email')
ORDER BY p.post_date DESC LIMIT 10;
```

### **3. User Management**

```sql
-- Find users with specific capabilities
SELECT u.user_login, u.user_email, um.meta_value as capabilities
FROM wp_users u
JOIN wp_usermeta um ON u.ID = um.user_id
WHERE um.meta_key = 'wp_capabilities'
AND um.meta_value LIKE '%administrator%';
```

### **4. Content Analysis**

```sql
-- Find posts with specific custom fields
SELECT p.post_title, pm.meta_key, pm.meta_value
FROM wp_posts p
JOIN wp_postmeta pm ON p.ID = pm.post_id
WHERE p.post_status = 'publish'
AND pm.meta_key = '_featured_image'
ORDER BY p.post_date DESC;
```

## 🔍 **How It Works**

### **Automatic Detection**

The MCP server automatically detects your active Local by Flywheel MySQL instance by:

1. **Process Detection**: Scans running processes for active mysqld instances
2. **Config Parsing**: Extracts MySQL configuration from the active Local site
3. **Dynamic Connection**: Connects using the correct socket path automatically
4. **Fallback Support**: Falls back to environment variables for custom setups

### **Local Directory Structure**

```
~/Library/Application Support/Local/run/
├── lx97vbzE7/                    # Dynamic site ID (changes on restart)
│   ├── conf/mysql/my.cnf        # MySQL configuration
│   └── mysql/mysqld.sock        # Socket connection
└── WP7lolWDi/                   # Another site
    ├── conf/mysql/my.cnf
    └── mysql/mysqld.sock
```

## 🛡️ **Security Features**

- **Read-only operations**: Only SELECT/SHOW/DESCRIBE/EXPLAIN allowed
- **Single statement**: Multiple statements blocked
- **Local development**: Designed for local environments only
- **No external connections**: Prioritizes Unix socket connections
- **Process isolation**: Runs in separate process from your applications

## 🔧 **Troubleshooting**

### **Common Issues**

**"No active MySQL process found"**

- Ensure Local by Flywheel is running
- Make sure at least one site is started in Local
- Check that the site's database is running

**"MySQL socket not found"**

- Verify the Local site is fully started
- Try stopping and restarting the site in Local
- Check Local's logs for MySQL startup issues

**"Connection refused"**

- Ensure the Local site's MySQL service is running
- Check if another process is using the MySQL port
- Try restarting Local by Flywheel

### **Debug Mode**

```bash
# Enable debug logging
DEBUG=mcp-local-wp ./providers/localhost-helper.sh start-mcp
```

## 🎉 **Benefits for AI Development**

✅ **No more schema guessing** - AI sees actual tables and columns
✅ **Accurate JOIN operations** - AI understands table relationships
✅ **Real data validation** - AI verifies data exists before suggesting queries
✅ **Plugin-aware development** - AI adapts to any plugin's custom tables
✅ **Instant debugging** - Complex queries become 5-second tasks
✅ **Zero configuration** - Works automatically with Local by Flywheel

---

**Transform your WordPress development workflow with AI that actually understands your database!**
