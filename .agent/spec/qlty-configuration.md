# Qlty CLI Configuration Guide

## Overview

Qlty CLI provides universal code quality analysis and auto-formatting for 40+ languages with 70+ static analysis tools. This guide covers complete configuration for multi-organization support.

## Organization Configuration

### Required Components

1. **Coverage Token** (`qltcw_...`): Required for Qlty CLI functionality
2. **Workspace ID** (UUID): Optional but recommended for workspace-specific features

### Storage Format

```bash
# Coverage Token
qlty-ORGNAME=qltcw_your_coverage_token_here

# Workspace ID  
qlty-ORGNAME-workspace-id=your-workspace-uuid-here
```

## Current Configuration

### marcusquinn Organization

- **Coverage Token**: `qltcw_scEDR369Uu3JU7UH`
- **Workspace ID**: `19642b88-f0d2-45d5-8a09-c539049b0d20`
- **Status**: ✅ Fully configured and tested

## Setup Instructions

### 1. Store Organization Configuration

```bash
# Store Coverage Token
bash .agent/scripts/setup-local-api-keys.sh set qlty-ORGNAME YOUR_COVERAGE_TOKEN

# Store Workspace ID (optional)
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

- **Location**: `~/.config/ai-assisted-devops/api-keys`
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
