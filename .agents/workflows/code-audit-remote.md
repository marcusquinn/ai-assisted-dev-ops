---
description: Remote code auditing using external services (CodeRabbit, Codacy, SonarCloud)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Code Audit Remote - External Quality Services

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Run remote code auditing via external service APIs
- **Services**: CodeRabbit (AI review), Codacy (quality), SonarCloud (security)
- **Script**: `~/.aidevops/agents/scripts/code-audit-helper.sh`
- **When**: PR review phase, after local linting passes
- **Position**: `/linters-local` -> `/code-audit-remote` -> `/pr` summary

```bash
# Run all remote audits
bash ~/.aidevops/agents/scripts/code-audit-helper.sh audit [repo]

# Report / status
bash ~/.aidevops/agents/scripts/code-audit-helper.sh report [repo] [output.json]
bash ~/.aidevops/agents/scripts/code-audit-helper.sh summary
bash ~/.aidevops/agents/scripts/code-audit-helper.sh status
bash ~/.aidevops/agents/scripts/code-audit-helper.sh check-regression
bash ~/.aidevops/agents/scripts/code-audit-helper.sh reset

# Individual service collectors
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh review
bash ~/.aidevops/agents/scripts/coderabbit-cli.sh analyze .agents/scripts/
bash ~/.aidevops/agents/scripts/codacy-cli.sh analyze
bash ~/.aidevops/agents/scripts/codacy-cli.sh upload results.sarif
bash ~/.aidevops/agents/scripts/sonarcloud-cli.sh analyze
```

<!-- AI-CONTEXT-END -->

## Services

| Service | Focus | Strengths | API |
|---------|-------|-----------|-----|
| **CodeRabbit** | AI-powered code reviews | Context-aware suggestions, security analysis, best practices | REST + MCP |
| **Codacy** | Code quality analysis | 40+ languages, auto-fix for safe violations, team collaboration | REST + CLI |
| **SonarCloud** | Security & maintainability | Industry standard rules, quality gates, tech debt tracking | Web API |

Complements `/linters-local` (fast, offline checks) with deeper, service-backed analysis.

## Output Format

Example report structure:

```markdown
## Remote Audit Results

### CodeRabbit Analysis
- **Overall**: 2 suggestions (minor)
- **Security**: No issues detected
- **Best Practices**: Consider using async/await in `utils.js:45`

### Codacy Analysis
- **Grade**: A (maintained)
- **Issues**: 3 code patterns detected
- **Auto-fixable**: 2 issues can be auto-fixed

### SonarCloud Analysis
- **Quality Gate**: Passed
- **Bugs**: 0 | **Vulnerabilities**: 0
- **Code Smells**: 1 (S1192 - repeated string)
- **Technical Debt**: 15 minutes
```

## Quality Gate Thresholds

| Metric | Minimum | Target |
|--------|---------|--------|
| Code Coverage | Repository-configured threshold, if any | Project-defined target |
| Bugs | 0 major | 0 total |
| Vulnerabilities | 0 high | 0 total |
| Code Smells | <10 major | <5 total |
| Duplicated Lines | <3% | <1% |

## CI/CD Integration

```yaml
name: Code Quality Audit
on: [push, pull_request]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Code Audit
        run: |
          bash .agents/scripts/code-audit-helper.sh audit ${{ github.repository }}
          bash .agents/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
      - name: Upload Report
        uses: actions/upload-artifact@v4
        with:
          name: audit-report
          path: audit-report.json
```

## Configuration

```bash
# Copy template, then add your service API tokens
cp configs/code-audit-config.json.txt configs/code-audit-config.json
```

Config structure (`configs/code-audit-config.json`):

```json
{
  "services": {
    "coderabbit": {
      "accounts": {
        "personal": {
          "api_token": "YOUR_CODERABBIT_API_TOKEN_HERE",
          "base_url": "https://api.coderabbit.ai/v1"
        }
      }
    },
    "codacy": {
      "accounts": {
        "organization": {
          "api_token": "YOUR_CODACY_API_TOKEN_HERE",
          "base_url": "https://app.codacy.com/api/v3"
        }
      }
    },
    "sonarcloud": {
      "accounts": {
        "personal": {
          "api_token": "YOUR_SONARCLOUD_TOKEN_HERE",
          "base_url": "https://sonarcloud.io/api"
        }
      }
    }
  }
}
```

## Related

- **Local linting**: `scripts/linters-local.sh`
- **Standards reference**: `tools/code-review/code-standards.md`
- **Unified PR review**: `workflows/pr.md`
- **Auditing details**: `tools/code-review/auditing.md`
