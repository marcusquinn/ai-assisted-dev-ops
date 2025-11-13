# Git Platforms Management Guide

Comprehensive Git platform management across GitHub, GitLab, Gitea, and local Git repositories with AI assistant integration and MCP support.

## 🏢 **Platforms Overview**

### **Supported Git Platforms:**

#### **GitHub**

- **Focus**: World's largest code hosting platform
- **Strengths**: Massive community, excellent CI/CD, comprehensive API
- **API**: Full REST API v4 with GraphQL support
- **MCP**: Official MCP server available
- **Use Case**: Open source projects, team collaboration, enterprise development

#### **GitLab**

- **Focus**: Complete DevOps platform with integrated CI/CD
- **Strengths**: Built-in CI/CD, security scanning, project management
- **API**: Comprehensive REST API v4
- **MCP**: Community MCP servers available
- **Use Case**: Enterprise DevOps, self-hosted solutions, integrated workflows

#### **Gitea**

- **Focus**: Lightweight self-hosted Git service
- **Strengths**: Minimal resource usage, easy deployment, Git-focused
- **API**: REST API compatible with GitHub API
- **MCP**: Community MCP servers available
- **Use Case**: Self-hosted Git, private repositories, lightweight deployments

#### **Local Git**

- **Focus**: Local repository management and initialization
- **Strengths**: Offline development, full control, no external dependencies
- **Integration**: Seamless integration with remote platforms
- **Use Case**: Local development, repository initialization, offline work

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/git-platforms-config.json.txt configs/git-platforms-config.json

# Edit with your platform credentials
```

### **Multi-Platform Configuration:**

```json
{
  "platforms": {
    "github": {
      "accounts": {
        "personal": {
          "api_token": "YOUR_GITHUB_PERSONAL_ACCESS_TOKEN_HERE",
          "username": "your-github-username",
          "base_url": "https://api.github.com",
          "description": "Personal GitHub account"
        }
      }
    },
    "gitlab": {
      "accounts": {
        "self-hosted": {
          "api_token": "YOUR_GITLAB_TOKEN_HERE",
          "username": "your-username",
          "base_url": "https://gitlab.yourdomain.com/api/v4",
          "description": "Self-hosted GitLab instance"
        }
      }
    }
  }
}
```

### **API Token Setup:**

#### **GitHub Personal Access Token:**

1. Go to **Settings** → **Developer settings** → **Personal access tokens**
2. Generate new token (classic) with permissions:
   - `repo` (Full control of private repositories)
   - `admin:repo_hook` (Read and write repository hooks)
   - `user` (Read user profile data)
3. **Store securely**: `bash .agent/scripts/setup-local-api-keys.sh set github YOUR_TOKEN`

#### **GitLab Personal Access Token:**

1. Go to **User Settings** → **Access Tokens**
2. Create personal access token with scopes:
   - `api` (Access the authenticated user's API)
   - `read_repository`, `write_repository`
   - `read_user`
3. **Store securely**: `bash .agent/scripts/setup-local-api-keys.sh set gitlab YOUR_TOKEN`

#### **Gitea Access Token:**

1. Go to **Settings** → **Applications**
2. Generate new access token
3. **Store securely**: `bash .agent/scripts/setup-local-api-keys.sh set gitea YOUR_TOKEN`

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all configured platforms
./providers/git-platforms-helper.sh platforms

# List repositories/projects
./providers/git-platforms-helper.sh github-repos personal public
./providers/git-platforms-helper.sh gitlab-projects personal private
./providers/git-platforms-helper.sh gitea-repos self-hosted
```

### **Repository Management:**

```bash
# Create new repositories
./providers/git-platforms-helper.sh github-create personal my-new-repo "Project description" false
./providers/git-platforms-helper.sh gitlab-create personal my-project "Project description" private
./providers/git-platforms-helper.sh gitea-create self-hosted my-repo "Repository description" true

# Clone repositories
./providers/git-platforms-helper.sh clone github personal my-repo ~/projects
./providers/git-platforms-helper.sh clone gitlab personal my-project ~/work
```

### **Local Git Management:**

```bash
# Initialize local repository
./providers/git-platforms-helper.sh local-init ~/projects my-new-project

# List local repositories
./providers/git-platforms-helper.sh local-list ~/projects

# List all local Git repositories
./providers/git-platforms-helper.sh local-list
```

### **Repository Auditing:**

```bash
# Audit repositories across platforms
./providers/git-platforms-helper.sh audit github personal
./providers/git-platforms-helper.sh audit gitlab self-hosted
./providers/git-platforms-helper.sh audit gitea self-hosted
```

## 🛡️ **Security Best Practices**

### **API Security:**

- **Token scoping**: Use tokens with minimal required permissions
- **Regular rotation**: Rotate API tokens every 6-12 months
- **Secure storage**: Store tokens in `~/.config/aidevops/` (user-private only)
- **Access monitoring**: Monitor API usage and access patterns
- **Environment separation**: Use different tokens for different environments
- **Never in repository**: API tokens must never be stored in repository files

### **Repository Security:**

```bash
# Security recommendations from audit
./providers/git-platforms-helper.sh audit github personal

# Key security practices:
- Enable two-factor authentication
- Use SSH keys for authentication
- Review repository permissions regularly
- Enable branch protection rules
- Use signed commits where possible
```

### **Access Control:**

- **Branch protection**: Enable branch protection rules for main branches
- **Required reviews**: Require code reviews for pull requests
- **Status checks**: Require status checks to pass before merging
- **Signed commits**: Use GPG signing for commit verification
- **Team permissions**: Implement proper team-based permissions

## 📊 **MCP Integration**

### **Available MCP Servers:**

#### **GitHub MCP Server:**

```bash
# Start GitHub MCP server
./providers/git-platforms-helper.sh start-mcp github 3006

# Configure in AI assistant
{
  "github": {
    "command": "github-mcp-server",
    "args": ["--port", "3006"],
    "env": {
      "GITHUB_TOKEN": "${GITHUB_API_TOKEN}"
    }
  }
}
```

#### **GitLab MCP Server:**

```bash
# Start GitLab MCP server (if available)
./providers/git-platforms-helper.sh start-mcp gitlab 3007

# Configure in AI assistant
{
  "gitlab": {
    "command": "gitlab-mcp-server",
    "args": ["--port", "3007"],
    "env": {
      "GITLAB_TOKEN": "your-token",
      "GITLAB_URL": "https://gitlab.yourdomain.com"
    }
  }
}
```

### **AI Assistant Capabilities:**

With MCP integration, AI assistants can:

- **Repository management**: Create, clone, and manage repositories
- **Code analysis**: Analyze repository contents and structure
- **Issue tracking**: Manage issues and pull requests
- **CI/CD monitoring**: Monitor build and deployment status
- **Team collaboration**: Manage team access and permissions
- **Security auditing**: Audit repository security settings

## 🔄 **Development Workflows**

### **Project Initialization Workflow:**

```bash
# Complete project setup workflow
1. Create local repository: local-init ~/projects my-new-project
2. Create remote repository: github-create personal my-new-project "Description" false
3. Add remote origin: cd ~/projects/my-new-project && git remote add origin https://github.com/username/my-new-project.git
4. Push initial commit: git push -u origin main
```

### **Multi-Platform Workflow:**

```bash
# Mirror repository across platforms
1. Create on GitHub: github-create personal my-project "Description" false
2. Create on GitLab: gitlab-create personal my-project "Description" private
3. Set up multiple remotes:
   git remote add github https://github.com/username/my-project.git
   git remote add gitlab https://gitlab.com/username/my-project.git
4. Push to both: git push github main && git push gitlab main
```

### **Team Collaboration Workflow:**

```bash
# Set up team repository
1. Create organization repository: github-create organization team-project "Team project" true
2. Set up branch protection rules
3. Add team members with appropriate permissions
4. Configure CI/CD workflows
5. Set up issue and PR templates
```

## 📚 **Best Practices**

### **Repository Organization:**

1. **Consistent naming**: Use consistent naming conventions across platforms
2. **Clear descriptions**: Provide clear, descriptive repository descriptions
3. **Proper licensing**: Include appropriate licenses for your projects
4. **Documentation**: Maintain comprehensive README files
5. **Issue templates**: Use issue and PR templates for consistency

### **Branch Management:**

- **Protected branches**: Protect main/master branches from direct pushes
- **Feature branches**: Use feature branches for development
- **Naming conventions**: Use consistent branch naming conventions
- **Regular cleanup**: Clean up merged and stale branches
- **Release branches**: Use release branches for production deployments

### **Collaboration:**

- **Code reviews**: Require code reviews for all changes
- **Clear commits**: Write clear, descriptive commit messages
- **Issue tracking**: Use issues to track bugs and feature requests
- **Documentation**: Keep documentation up to date
- **Communication**: Use PR descriptions to explain changes

## 🎯 **AI Assistant Integration**

### **Automated Repository Management:**

- **Repository creation**: AI can create repositories across platforms
- **Code analysis**: AI can analyze repository structure and content
- **Issue management**: AI can create and manage issues and PRs
- **Security auditing**: AI can audit repository security settings
- **Team management**: AI can manage team access and permissions

### **Development Assistance:**

- **Project scaffolding**: AI can initialize projects with templates
- **Code review**: AI can assist with code review processes
- **Documentation**: AI can generate and update documentation
- **CI/CD setup**: AI can configure CI/CD workflows
- **Deployment**: AI can manage deployment processes

---

**The Git platforms framework provides comprehensive version control management across multiple platforms with AI assistant integration for automated development workflows.** 🚀
