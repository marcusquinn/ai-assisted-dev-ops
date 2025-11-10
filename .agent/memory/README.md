# AI Assistant Memory Directory

This directory is designated for AI assistants to store persistent memory, context, and learning data across sessions.

## 🎯 **Purpose**

AI assistants should use this directory for:

- **Session context** and conversation history
- **Learning data** from previous operations
- **Configuration preferences** discovered during use
- **Operation patterns** and successful approaches
- **Error patterns** and solutions
- **User preferences** and customizations

## 📋 **Usage Guidelines**

### **✅ DO Use This Directory For:**

- Persistent context that should survive between sessions
- Learning from successful operations and patterns
- Storing user preferences and customizations
- Remembering configuration details and setups
- Tracking operation history and outcomes
- Caching frequently used data and configurations

### **❌ DON'T Use This Directory For:**

- Sensitive credentials or passwords (use secure storage)
- Large binary files or media
- Temporary working files (use .agent/tmp/ instead)
- User-facing documentation or configs

## 🔒 **Security Considerations**

- **No credentials**: Never store passwords, API keys, or sensitive data
- **Privacy aware**: Be mindful of user privacy in stored context
- **Gitignore**: This directory is ignored by Git for privacy protection
- **Local only**: Memory files should remain on the local system

## 📁 **Recommended Structure**

```text
.agent/memory/
├── context/                 # Session context and history
├── patterns/                # Learned operation patterns
├── preferences/             # User preferences and customizations
├── configurations/          # Discovered configuration patterns
├── solutions/               # Successful problem solutions
└── analytics/               # Usage analytics and insights
```

## 🔧 **Example Usage**

```bash
# Store successful operation pattern
cat > .agent/memory/patterns/bulk-quality-fixes.md << 'EOF'
# Bulk Quality Fix Pattern
Successfully used Python scripts for bulk operations:
- 25+ files processed simultaneously
- Universal patterns applied consistently
- Much more efficient than individual edits
EOF

# Remember user preferences
echo "preferred_editor=vim" > .agent/memory/preferences/user-settings.conf

# Store configuration discovery
cat > .agent/memory/configurations/sonarcloud-setup.md << 'EOF'
# SonarCloud Configuration Learned
- Project key: marcusquinn_ai-assisted-dev-ops
- Quality gates: A-grade maintained
- Issue types: S7682, S7679, S1192, S1481
EOF

# Cache frequently used data
echo "last_quality_check=$(date)" > .agent/memory/analytics/last-operations.log
```

This directory enables AI assistants to learn and improve over time while maintaining user privacy and security.
