# AI-Assisted DevOps Framework - Master Guide

## 🎯 **AUTHORITATIVE GUIDANCE FOR AI AGENTS**

This is the **SINGLE SOURCE OF TRUTH** for AI agents working on this repository. All other guidance files are supplementary and must not conflict with this master guide.

### **Current Quality Status**
- **SonarCloud**: 66 issues (Target: <50)
- **Codacy**: A+ rating achieved (✅ EXCELLENCE)
- **Critical Issues**: S7679 & S1481 = 0 (✅ RESOLVED)
- **String Literals**: Major progress (75+ violations eliminated)
- **Platform Ratings**: A+ Codacy, A-grade CodeFactor maintained

## 🚨 **CRITICAL SECURITY REQUIREMENTS**

### **🔐 API Key Security (ZERO TOLERANCE)**
```bash
# ✅ CORRECT: Use secure local storage
bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_TOKEN
bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_TOKEN

# ✅ CORRECT: GitHub Actions use secrets
env:
  CODACY_API_TOKEN: ${{ secrets.CODACY_API_TOKEN }}

# ✅ CORRECT: Load from secure storage
bash .agent/scripts/setup-local-api-keys.sh load

# ❌ NEVER: Hardcode API keys in code
readonly API_TOKEN="abc123"  # SECURITY BREACH!
```

**MANDATORY RULES:**
- **NEVER** commit API keys to repository
- **ALWAYS** use secure local storage (`~/.config/ai-assisted-devops/`)
- **NEVER** store API keys in repository files or documentation
- **IMMEDIATELY** revoke any exposed keys
- **ALWAYS** add sensitive configs to .gitignore

## 🚨 **MANDATORY QUALITY REQUIREMENTS**

### **Shell Script Standards (NON-NEGOTIABLE)**

#### **1. Function Structure (S7682 Compliance)**
```bash
# ✅ REQUIRED Pattern
function_name() {
    local param1="$1"
    local param2="$2"
    
    # Function logic here
    
    return 0  # MANDATORY: Every function must have explicit return
}
```

#### **2. Variable Declaration (SC2155 Compliance)**
```bash
# ✅ CORRECT: Separate declaration and assignment
local variable_name
variable_name=$(command_here)

# ❌ INCORRECT: Combined declaration/assignment
local variable_name=$(command_here)  # Triggers SC2155
```

#### **3. String Literal Management (S1192 Compliance)**
```bash
# ✅ CORRECT: Use constants for 3+ occurrences
readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly AUTH_BEARER_PREFIX="Authorization: Bearer"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"

# Usage
curl -H "$CONTENT_TYPE_JSON" "$url"
print_error "$ERROR_UNKNOWN_COMMAND $command"
```

#### **4. Positional Parameter Handling (S7679 Compliance)**
```bash
# ✅ CORRECT: Use printf format strings for dollar amounts
printf 'Price: %s50/month\n' '$'

# ❌ INCORRECT: Direct dollar amounts
echo "Price: $50/month"  # Triggers S7679 (interpreted as $5 + 0)
```

#### **5. Codacy A+ Rating Requirements**
```bash
# ✅ CORRECT: Security - Pin GitHub Actions to commit SHA
uses: SonarSource/sonarqube-scan-action@fd88b7d # v6.0.0

# ✅ CORRECT: No unused variables
# Remove unused variables or use them meaningfully

# ✅ CORRECT: Proper regex patterns in shell
if [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then

# ❌ INCORRECT: Unpinned actions
uses: SonarSource/sonarqube-scan-action@v6  # Security risk
```

### **Quality Issue Resolution Priority**

#### **Phase 1: Critical Issues (COMPLETED ✅)**
1. **S7679 (Positional Parameters)**: 100% resolved
2. **S1481 (Unused Variables)**: 100% resolved through functionality enhancement

#### **Phase 2: High-Impact Issues (IN PROGRESS 📊)**
1. **S7682 (Return Statements)**: Add explicit returns to all functions
2. **S1192 (String Literals)**: Target 3+ occurrences for constant creation

#### **Phase 3: Code Quality (ONGOING 🔧)**
1. **ShellCheck Issues**: SC2155, SC2181, SC2317 resolution
2. **Markdown Quality**: Professional formatting compliance

### **Development Workflow (MANDATORY)**

#### **Pre-Development Checklist**
1. **Run quality check**: `bash .agent/scripts/quality-check.sh`
2. **Identify target issues**: Focus on highest-impact violations
3. **Plan enhancements**: How will changes improve functionality?

#### **Post-Development Validation**
1. **Quality verification**: Re-run quality-check.sh
2. **Functionality testing**: Ensure all features work
3. **Commit with metrics**: Include before/after quality improvements

### **Available Quality Tools**

#### **Core Quality Scripts**
- **quality-check.sh**: Master quality validator (run before/after changes)
- **add-missing-returns.sh**: Fix S7682 return statement issues
- **fix-content-type.sh**: Consolidate Content-Type headers
- **fix-auth-headers.sh**: Standardize Authorization headers
- **fix-error-messages.sh**: Create error message constants

#### **Multi-Platform CLI Integration**
- **CodeRabbit**: `bash .agent/scripts/coderabbit-cli.sh review`
- **Codacy**: `bash .agent/scripts/codacy-cli.sh analyze` (✅ A+ RATING)
- **SonarScanner**: `bash .agent/scripts/sonarscanner-cli.sh analyze`

### **Success Criteria**

#### **Quality Targets**
- **SonarCloud**: <50 total issues
- **Codacy**: A+ rating (✅ ACHIEVED)
- **Critical Issues**: 0 S7679, 0 S1481 violations (✅ ACHIEVED)
- **Return Statements**: 0 S7682 violations
- **String Literals**: <10 S1192 violations
- **Security**: All GitHub Actions pinned to commit SHA (✅ ACHIEVED)
- **Functionality**: 100% preservation + enhancement

#### **Commit Standards**
Include quality metrics in every commit:
```
🔧 FEATURE: Description of changes

✅ QUALITY IMPROVEMENTS:
- SonarCloud: X → Y issues (Z issues resolved)
- Fixed: Specific violations addressed
- Enhanced: Functionality improvements made

📊 METRICS: Before/after quality measurements
```

## 🎯 **CORE PRINCIPLE: FUNCTIONALITY ENHANCEMENT**

**NEVER remove functionality to fix quality issues. Always enhance code to resolve violations while adding value.**

This master guide supersedes all other guidance documents and provides the authoritative reference for maintaining our industry-leading quality standards.
