# Qlty CLI Configuration Guide

## Overview

Qlty CLI provides universal code quality analysis and auto-formatting for 40+ languages with 70+ static analysis tools. This guide covers complete configuration for multi-organization support.

## Qlty Credential Types & Configuration

### Credential Hierarchy

Qlty CLI supports multiple credential types with intelligent selection:

1. **Account API Key** (`qltp_...`) - **PREFERRED**
   - Account-wide access to all workspaces
   - Broader permissions and functionality
   - Single credential for entire account

2. **Coverage Token** (`qltcw_...`) - Organization-specific
   - Workspace-specific access
   - Used when account API key unavailable
   - Organization-scoped permissions

3. **Workspace ID** (UUID) - Context identifier
   - Optional but recommended
   - Provides workspace context for operations
   - Used with either credential type

### Storage Format

```bash
# Account-level API Key (preferred)
qlty-account-api-key=qltp_your_account_api_key_here

# Organization-specific Coverage Token
qlty-ORGNAME=qltcw_your_coverage_token_here

# Workspace ID (optional but recommended)
qlty-ORGNAME-workspace-id=your-workspace-uuid-here
```

### Intelligent Credential Selection

The CLI automatically selects the best available credential:

1. **Account API Key** - Used if available (preferred for broader access)
2. **Coverage Token** - Used as fallback for organization-specific access
3. **Workspace ID** - Always loaded when available for context

## Current Configuration

### Account-Level Configuration

- **Account API Key**: `qltp_WTc5AqtTGUWZNVLjsAWD4Ev6c8jslv1j2MsLI6qA`
- **Access Level**: Account-wide (all workspaces)
- **Status**: ✅ Active and preferred

### marcusquinn Organization

- **Coverage Token**: `qltcw_scEDR369Uu3JU7UH` (fallback)
- **Workspace ID**: `19642b88-f0d2-45d5-8a09-c539049b0d20`
- **Status**: ✅ Fully configured (used for workspace context)

### Credential Selection Logic

- **Primary**: Account API Key provides account-wide access
- **Context**: Workspace ID provides organization-specific context
- **Fallback**: Coverage Token available if account key unavailable

## Setup Instructions

### 1. Store Qlty Configuration

```bash
# PREFERRED: Store Account API Key (account-wide access)
bash .agent/scripts/setup-local-api-keys.sh set qlty-account-api-key YOUR_ACCOUNT_API_KEY

# ALTERNATIVE: Store Coverage Token (organization-specific)
bash .agent/scripts/setup-local-api-keys.sh set qlty-ORGNAME YOUR_COVERAGE_TOKEN

# OPTIONAL: Store Workspace ID (context for operations)
bash .agent/scripts/setup-local-api-keys.sh set qlty-ORGNAME-workspace-id YOUR_WORKSPACE_ID
```

### 2. Verify Configuration

```bash
# List all configured services
bash .agent/scripts/setup-local-api-keys.sh list

# Check Qlty CLI help (shows configured organizations)
bash .agent/scripts/qlty-cli.sh help
```

### 3. Test Functionality

```bash
# Install Qlty CLI
bash .agent/scripts/qlty-cli.sh install

# Initialize repository
bash .agent/scripts/qlty-cli.sh init

# Test with default organization
bash .agent/scripts/qlty-cli.sh check 5

# Test with specific organization
bash .agent/scripts/qlty-cli.sh check 5 ORGNAME
```

## Usage Examples

### Default Organization (marcusquinn)

```bash
# Code quality check
bash .agent/scripts/qlty-cli.sh check

# Auto-format all files
bash .agent/scripts/qlty-cli.sh fmt --all

# Detect code smells
bash .agent/scripts/qlty-cli.sh smells --all
```

### Specific Organization

```bash
# Code quality check for 'mycompany' organization
bash .agent/scripts/qlty-cli.sh check 10 mycompany

# Auto-format for 'clientorg' organization
bash .agent/scripts/qlty-cli.sh fmt --all clientorg

# Code smells for 'teamproject' organization
bash .agent/scripts/qlty-cli.sh smells --all teamproject
```

## Multi-Organization Management

### Adding New Organizations

1. **Obtain Credentials**: Get Coverage Token and Workspace ID from Qlty dashboard
2. **Store Securely**: Use setup-local-api-keys.sh for secure storage
3. **Test Configuration**: Verify functionality with test commands
4. **Document**: Update this guide with new organization details

### Organization Naming Convention

- **Coverage Token**: `qlty-ORGNAME`
- **Workspace ID**: `qlty-ORGNAME-workspace-id`
- **Usage**: Commands accept `ORGNAME` parameter

## Security Features

### Secure Storage

- **Location**: `~/.config/aidevops/api-keys`
- **Permissions**: User-only access (600)
- **Encryption**: Local file system security
- **No Exposure**: Tokens never appear in code or logs

### Best Practices

1. **Never commit tokens** to version control
2. **Use organization-specific naming** for clarity
3. **Store both token and workspace ID** for complete functionality
4. **Test configuration** after setup
5. **Document organization details** for team reference

## Troubleshooting

### Common Issues

1. **Token Not Found**: Verify storage with `setup-local-api-keys.sh list`
2. **CLI Not Found**: Ensure PATH includes `~/.qlty/bin`
3. **Permission Denied**: Check file permissions on API key storage
4. **Organization Not Recognized**: Verify naming convention matches

### Verification Commands

```bash
# Check stored configurations
bash .agent/scripts/setup-local-api-keys.sh list

# Test token loading
bash .agent/scripts/qlty-cli.sh check 1 ORGNAME

# Verify CLI installation
qlty --version
```

## Integration

### Quality CLI Manager

Qlty CLI integrates with the unified Quality CLI Manager:

```bash
# Install all quality tools including Qlty
bash .agent/scripts/quality-cli-manager.sh install all

# Run Qlty analysis through manager
bash .agent/scripts/quality-cli-manager.sh analyze qlty
```

### GitHub Actions

Qlty CLI can be integrated into CI/CD pipelines with proper secret management for Coverage Tokens and Workspace IDs.

## Support

For additional organizations or configuration issues:

1. **Obtain credentials** from Qlty dashboard
2. **Follow setup instructions** in this guide  
3. **Test functionality** with provided commands
4. **Update documentation** with new organization details
