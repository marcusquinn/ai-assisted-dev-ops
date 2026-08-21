---
description: Guidelines for extending the framework
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Framework Extension Guidelines

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Workflow**: Research → Helper script → Config template → Documentation → Update framework files
- **Helper**: `.agents/scripts/[service]-helper.sh`
- **Config template**: `configs/[service]-config.json.txt`
- **Docs**: `.agents/[service].md`
- **Required functions**: `check_dependencies`, `load_config`, `get_account_config`, `api_request`, `list_accounts`, `show_help`, `main`
- **Update on add**: `.gitignore`, `README.md`, `AGENTS.md`, `aidevops/recommendations.md`, `setup-wizard-helper.sh`

<!-- AI-CONTEXT-END -->

## Adding a New Service Provider

### Step 1: Research & Planning

```text
- Service has public API with documentation
- API supports required operations (list, create, update, delete)
- Authentication method supported (token, OAuth, etc.)
- Rate limits and usage policies acceptable
- MCP server available or can be created
- Fits existing framework categories
```

### Step 2: Create Helper Script

```bash
# File: .agents/scripts/[service]-helper.sh
#!/bin/bash

# [Service Name] Helper Script — [brief description]

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CONFIG_FILE="../configs/[service]-config.json"

# Required functions (implement all):
check_dependencies() { ... }
load_config() { ... }
get_account_config() { ... }
api_request() { ... }
list_accounts() { ... }
show_help() { ... }
main() { ... }

# Service-specific functions
[service_specific_functions]() { ... }

main "$@"
```

### Step 3: Create Configuration Template

```json
// File: configs/[service]-config.json.txt
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com",
      "description": "Personal [service] account",
      "username": "your-username"
    }
  },
  "default_settings": {
    "timeout": 30,
    "rate_limit": 60,
    "retry_attempts": 3,
    "page_size": 50
  },
  "mcp_servers": {
    "[service]": {
      "enabled": true,
      "port": 30,
      "host": "localhost",
      "auth_required": true
    }
  },
  "features": {
    "bulk_operations": true,
    "webhooks": false,
    "real_time_updates": true
  }
}
```

### Step 4: Create Documentation

```markdown
# File: .agents/[SERVICE].md
# [Service Name] Guide

## Provider Overview
- **Service Type**: [Description]
- **Strengths**: [Key benefits]
- **API Support**: [Capabilities and limitations]
- **MCP Integration**: [Server availability]

## Configuration
[Setup instructions]

## Usage Examples
[Commands with expected output]

## Security
[Service-specific security guidelines]

## MCP Integration
[Server setup and capabilities]

## Troubleshooting
[Common issues and solutions]
```

### Step 5: Update Framework Files

```bash
# .gitignore — add working config
echo "configs/[service]-config.json" >> .gitignore

# README.md — add to service list, helper scripts list, file structure
# AGENTS.md — add to appropriate service category
# .agents/aidevops/recommendations.md — add with description
# setup-wizard-helper.sh — add to recommendations, API keys guide, config generation
```

## Security Requirements

All new services must implement:

```text
- API token validation before use
- Input validation and sanitization
- Secure error messages (no credential exposure in logs/output)
- Rate limiting awareness and backoff
- Confirmation prompts for destructive operations
- Audit logging for important operations
- Encrypted credential storage (gopass preferred)
- Secure temporary file handling (cleanup on exit)
- File permissions properly set (600 for credentials)
- Configuration files gitignored
```

## Testing Checklist

```text
Functional:
- Configuration loading and validation
- API connectivity and authentication
- CRUD operations (list, create, update, delete)
- Error handling and recovery
- Help output

Integration:
- Helper script follows naming conventions
- Configuration follows standard structure
- Documentation follows standard format
- MCP server integration (if applicable)
- Setup wizard integration

Security:
- No credential exposure in any output
- Proper input validation
- Secure error handling
- File permission verification
```

## Maintenance

- Monitor service API changes — update helper when endpoints change
- Semantic versioning for breaking changes; provide migration guides
- Keep documentation current; deprecation notices before removal
