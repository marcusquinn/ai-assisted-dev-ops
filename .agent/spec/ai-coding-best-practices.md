# AI-Assisted Coding Best Practices

## Framework-Specific Guidelines for AI Agents

> **⚠️ IMPORTANT**: This document is supplementary to the [AGENTS.md](../../AGENTS.md).
> For any conflicts, the main AGENTS.md takes precedence as the single source of truth.

### Overview

This document provides detailed implementation examples and advanced patterns for AI agents working on the AI DevOps Framework.

### Code Quality Requirements

#### Shell Script Standards (MANDATORY)

**These patterns are REQUIRED for SonarCloud/CodeFactor/Codacy compliance:**

```bash
# ✅ CORRECT Function Structure
function_name() {
    local param1="$1"
    local param2="$2"
    
    # Function logic here
    
    return 0  # MANDATORY: Every function must have explicit return
}

# ✅ CORRECT Variable Declaration (SC2155 compliance)
local variable_name
variable_name=$(command_here)

# ✅ CORRECT String Literal Management (S1192 compliance)
readonly COMMON_STRING="repeated text"
echo "$COMMON_STRING"  # Use constant for 3+ occurrences

# ✅ CORRECT Positional Parameter Handling (S7679 compliance)
printf 'Price: %s50/month\n' '$'  # Not: echo "Price: $50/month"
```

#### Quality Issue Prevention

**Before making ANY changes, check for these patterns:**

1. **Positional Parameters**: Never use `$50`, `$200` in strings - use printf format
2. **String Literals**: If text appears 3+ times, create a readonly constant
3. **Unused Variables**: Every variable must be used or removed
4. **Return Statements**: Every function must end with `return 0` or appropriate code
5. **Variable Declaration**: Separate `local var` and `var=$(command)`

### Development Workflow

#### Pre-Development Checklist

1. **Run quality check**: `bash .agent/scripts/quality-check.sh`
2. **Check current issues**: Note SonarCloud/Codacy/CodeFactor status
3. **Plan improvements**: How will changes enhance quality?
4. **Test functionality**: Ensure no feature loss

#### Post-Development Validation

1. **Quality verification**: Re-run quality-check.sh
2. **Functionality testing**: Verify all features work
3. **Documentation updates**: Update AGENTS.md if needed
4. **Commit with metrics**: Include before/after quality metrics

### Common Patterns & Solutions

#### String Literal Consolidation

**Target patterns with 3+ occurrences:**

- HTTP headers: `Content-Type: application/json`, `Authorization: Bearer`
- Error messages: `Unknown command:`, `Usage:`, help text
- API endpoints: Repeated URLs or paths
- Configuration values: Common settings or defaults

```bash
# Create constants section after colors
readonly NC='\033[0m' # No Color

# Common constants
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
```

#### Error Message Standardization

**Consistent error handling patterns:**

```bash
# Error message constants
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_INVALID_OPTION="Invalid option"
readonly USAGE_PREFIX="Usage:"
readonly HELP_MESSAGE_SUFFIX="Show this help message"

# Usage in functions
print_error "$ERROR_UNKNOWN_COMMAND $command"
echo "$USAGE_PREFIX $0 [options]"
```

#### Function Enhancement Over Deletion

**When fixing unused variables, prefer enhancement:**

```bash
# ❌ DON'T: Remove functionality
# local port  # Removed to fix unused variable

# ✅ DO: Enhance functionality
local port
read -r port
if [[ -n "$port" && "$port" != "22" ]]; then
    ssh -p "$port" "$host"  # Enhanced SSH with port support
else
    ssh "$host"
fi
```

### Quality Tools Usage

#### Available Quality Scripts

- **quality-check.sh**: Run before and after changes
- **fix-content-type.sh**: Fix Content-Type header duplications
- **fix-auth-headers.sh**: Fix Authorization header patterns
- **fix-error-messages.sh**: Standardize error messages
- **markdown-formatter.sh**: Fix markdown formatting issues

#### Quality CLI Integration

```bash
# CodeRabbit analysis
bash .agent/scripts/coderabbit-cli.sh review

# Comprehensive analysis
bash .agent/scripts/quality-cli-manager.sh analyze all

# Individual platform analysis
bash .agent/scripts/codacy-cli.sh analyze
bash .agent/scripts/sonarscanner-cli.sh analyze
```

### Success Metrics

#### Quality Targets

- **SonarCloud**: <50 total issues (currently 42)
- **Critical Issues**: 0 S7679, 0 S1481 violations
- **String Literals**: <10 S1192 violations
- **ShellCheck**: <5 critical issues per file
- **Functionality**: 100% feature preservation

#### Commit Standards

**Include quality metrics in commit messages:**

```text
🔧 FEATURE: Enhanced SSH functionality with port support

✅ QUALITY IMPROVEMENTS:
- Fixed S1481: Unused 'port' variable → Enhanced SSH port support
- Maintained functionality: All existing SSH features preserved
- Added capability: Custom port support for non-standard configurations

📊 METRICS:
- SonarCloud: 43 → 42 issues (1 issue resolved)
- Functionality: 100% preserved + enhanced
```

This framework maintains industry-leading quality standards through systematic application of these practices.
