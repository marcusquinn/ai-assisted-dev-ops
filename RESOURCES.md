# AI DevOps Resources

## Code Quality & Linting Tools

### CodeFactor Linters Collection

CodeFactor uses a comprehensive collection of open-source analysis tools. Our framework includes a linter manager based on their collection.

**Reference**: [CodeFactor Analysis Tools](https://docs.codefactor.io/bootcamp/analysis-tools/)

#### Language-Specific Linters

| Language | Tools | Version | Configuration |
|----------|-------|---------|---------------|
| **Python** | pycodestyle, Pylint, Bandit, Ruff | Latest | setup.cfg, .pylintrc, .bandit |
| **JavaScript/TypeScript** | Oxlint, ESLint | Latest | .eslintrc.* |
| **CSS/SCSS/Less** | Stylelint | 16.25.0 | .stylelintrc* |
| **Shell** | ShellCheck | 0.11.0 | .shellcheckrc |
| **Docker** | Hadolint | 2.14.0 | .hadolint.yaml |
| **YAML** | Yamllint | 1.37.1 | .yamllint* |
| **Go** | Revive | 1.12.0 | revive.toml |
| **PHP** | PHP_CodeSniffer | 3.13.5 | phpcs.xml |
| **Ruby** | RuboCop, bundler-audit, Brakeman | Latest | .rubocop.yml |
| **Java** | Checkstyle | 12.1.1 | checkstyle.xml |
| **C#** | StyleCop.Analyzers | Latest | .editorconfig |
| **Swift** | SwiftLint | 0.62.1 | .swiftlint.yml |
| **Kotlin** | Detekt | 1.23.8 | detekt.yml |
| **Dart** | Linter for Dart | 3.10.0 | analysis_options.yaml |
| **R** | Lintr | 3.2.0 | .lintr |
| **C/C++** | CppLint, Flawfinder | Latest | CPPLINT.CFG |
| **Haskell** | HLint | 3.10 | .hlint.yaml |
| **Groovy** | CodeNarc | 3.6.0 | codenarc.xml |
| **PowerShell** | PSScriptAnalyzer | 1.24.0 | PSScriptAnalyzerSettings.psd1 |
| **Security** | Trivy | 0.67.2 | trivy.yaml |

#### Usage with Our Framework

```bash
# Detect languages in current project
bash .agent/scripts/linter-manager.sh detect

# Install linters for detected languages
bash .agent/scripts/linter-manager.sh install-detected

# Install all supported linters
bash .agent/scripts/linter-manager.sh install-all

# Install linters for specific language
bash .agent/scripts/linter-manager.sh install python
```

### Quality Analysis Platforms

#### Integrated Platforms

| Platform | Type | Integration | Auto-Fix |
|----------|------|-------------|----------|
| **CodeRabbit** | AI Code Review | ✅ CLI | ❌ Analysis Only |
| **Codacy** | Code Quality | ✅ CLI + Web | ✅ Auto-Fix |
| **SonarCloud** | Code Quality | ✅ CLI + Web | ❌ Analysis Only |
| **Qlty** | Universal Linting | ✅ CLI | ✅ Auto-Format |
| **CodeFactor** | Code Quality | 📚 Reference | ❌ Web Only |

#### Platform Comparison

**CodeRabbit**:

- AI-powered code review
- Pull request analysis
- Contextual suggestions
- No auto-fix capabilities

**Codacy**:

- Comprehensive code analysis
- 40+ languages supported
- Auto-fix for safe violations
- Web dashboard + CLI

**SonarCloud**:

- Enterprise-grade analysis
- Security vulnerability detection
- Technical debt tracking
- Analysis only (no auto-fix)

**Qlty**:

- Universal linting platform
- 70+ tools, 40+ languages
- Auto-formatting capabilities
- Account-wide and organization-specific access

**CodeFactor**:

- Comprehensive linter collection
- Reference for tool selection
- Web-based analysis
- Open-source tool integration

### Auto-Fix Capabilities

#### Tools with Auto-Fix Support

| Tool | Languages | Fix Types | Time Savings |
|------|-----------|-----------|--------------|
| **Codacy CLI** | Multi-language | Style, Best Practices, Security | 70-90% |
| **Qlty CLI** | 40+ Languages | Formatting, Linting, Smells | 80-95% |
| **ESLint** | JavaScript/TypeScript | Style, Best Practices | 60-80% |
| **Pylint** | Python | Style, Code Quality | 50-70% |
| **RuboCop** | Ruby | Style, Best Practices | 60-80% |
| **SwiftLint** | Swift | Style, Best Practices | 50-70% |

#### Auto-Fix Workflow

1. **Detection**: Identify code quality issues
2. **Analysis**: Determine safe fixes
3. **Application**: Apply fixes automatically
4. **Verification**: Validate changes
5. **Reporting**: Document applied fixes

### Configuration Management

#### Configuration Files by Tool

**Python**:

- `setup.cfg`: pycodestyle, flake8
- `.pylintrc`: Pylint configuration
- `.bandit`: Bandit security rules
- `pyproject.toml`: Modern Python configuration

**JavaScript/TypeScript**:

- `.eslintrc.js/.json/.yaml`: ESLint rules
- `tsconfig.json`: TypeScript configuration
- `.oxlintrc.json`: Oxlint configuration

**CSS/SCSS**:

- `.stylelintrc.json/.yaml`: Stylelint rules
- `stylelint.config.js`: JavaScript configuration

**Shell**:

- `.shellcheckrc`: ShellCheck configuration

**Docker**:

- `.hadolint.yaml`: Hadolint rules

**YAML**:

- `.yamllint.yaml`: Yamllint configuration

### Best Practices

#### Linter Selection

1. **Language Coverage**: Choose tools that cover your tech stack
2. **Auto-Fix Support**: Prioritize tools with automatic fixing
3. **Configuration**: Use standard configuration files
4. **Integration**: Ensure CI/CD compatibility
5. **Performance**: Consider analysis speed and resource usage

#### Configuration Strategy

1. **Start Conservative**: Begin with standard rule sets
2. **Customize Gradually**: Adjust rules based on team needs
3. **Document Decisions**: Maintain configuration rationale
4. **Version Control**: Track configuration changes
5. **Team Alignment**: Ensure team consensus on rules

#### Workflow Integration

1. **Pre-commit Hooks**: Run linters before commits
2. **CI/CD Pipeline**: Integrate with build process
3. **IDE Integration**: Configure editor plugins
4. **Auto-Fix Scheduling**: Regular automated fixes
5. **Quality Gates**: Block merges on quality issues

### Additional Resources

#### Documentation Links

- [CodeFactor Analysis Tools](https://docs.codefactor.io/bootcamp/analysis-tools/)
- [ESLint Rules](https://eslint.org/docs/rules/)
- [Pylint Messages](https://pylint.pycqa.org/en/latest/technical_reference/features.html)
- [ShellCheck Wiki](https://github.com/koalaman/shellcheck/wiki)
- [Stylelint Rules](https://stylelint.io/user-guide/rules/list)

#### Community Resources

- [Awesome Static Analysis](https://github.com/analysis-tools-dev/static-analysis)
- [Code Quality Tools](https://github.com/collections/code-quality)
- [Linting Best Practices](https://github.com/topics/linting)

This resource collection provides comprehensive guidance for implementing
code quality analysis and automated fixing in AI-assisted development workflows.
