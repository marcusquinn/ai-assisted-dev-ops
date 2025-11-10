# Context7 MCP Setup Guide

Context7 MCP provides AI assistants with real-time access to the latest documentation for thousands of development tools, frameworks, and libraries.

## 🎯 **What is Context7 MCP?**

Context7 MCP is a Model Context Protocol server that gives AI assistants access to:

- **Latest documentation** for popular development tools and frameworks
- **Version-specific** documentation and guides
- **AI-optimized** content format for better understanding
- **Real-time updates** as libraries and tools evolve
- **Comprehensive coverage** of the development ecosystem

## 🚀 **Benefits for AI-Assisted Development**

### **Before Context7 MCP:**

- AI assistants work with **outdated training data**
- **Guessing** at API changes and new features
- **Inconsistent** information across different versions
- **Limited** knowledge of recent tools and updates

### **After Context7 MCP:**

- **Real-time access** to latest documentation
- **Version-specific** guidance and examples
- **Accurate** API references and best practices
- **Comprehensive** coverage of your development stack

## 📦 **Installation & Setup**

### **Prerequisites:**

- **Node.js 18+** installed
- **npm or npx** available
- **AI assistant** that supports MCP (Claude Desktop, Cursor, etc.)

### **1. Test Context7 MCP Server:**

```bash
# Test the server (no installation needed with npx)
npx -y @context7/mcp-server@latest --help

# This should show the Context7 MCP server help
```

### **2. Add to Your AI Assistant Configuration:**

#### **For Claude Desktop:**

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server@latest"],
      "env": {
        "DEBUG": "false"
      }
    }
  }
}
```

#### **For Cursor IDE:**

Create/edit `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@context7/mcp-server@latest"]
    }
  }
}
```

#### **For Augment Agent:**

Context7 tools are **built-in** - no additional setup required!

- Use `resolve-library-id` tool to find library IDs
- Use `get-library-docs` tool to fetch documentation

### **3. Framework Configuration:**

```bash
# Copy the Context7 MCP configuration template
cp configs/context7-mcp-config.json.txt configs/context7-mcp-config.json

# Edit with your commonly used libraries and preferences
```

## 🔧 **Usage Examples**

### **1. Library Resolution:**

```bash
# Always resolve library names first
resolve-library-id("next.js")
# Returns: "/vercel/next.js"

resolve-library-id("react")
# Returns: "/facebook/react"

resolve-library-id("supabase")
# Returns: "/supabase/supabase"
```

### **2. Getting Documentation:**

```bash
# Get general documentation
get-library-docs("/vercel/next.js")

# Get topic-specific documentation
get-library-docs("/vercel/next.js", topic="routing")

# Get version-specific documentation
get-library-docs("/vercel/next.js/v14.3.0-canary.87")

# Adjust token limits for more/less detail
get-library-docs("/facebook/react", tokens=10000)
```

### **3. Common Development Workflows:**

#### **Starting a New Project:**

```bash
# Get setup documentation for your stack
resolve-library-id("next.js") -> get-library-docs("/vercel/next.js", topic="getting-started")
resolve-library-id("tailwind") -> get-library-docs("/tailwindlabs/tailwindcss", topic="installation")
resolve-library-id("prisma") -> get-library-docs("/prisma/prisma", topic="setup")
```

#### **Debugging Issues:**

```bash
# Get troubleshooting guides
get-library-docs("/vercel/next.js", topic="troubleshooting")

# Check API changes between versions
get-library-docs("/facebook/react/v18.2.0")
get-library-docs("/facebook/react/v18.3.0")
```

#### **Learning New Tools:**

```bash
# Comprehensive documentation for new library
resolve-library-id("drizzle-orm") -> get-library-docs("/drizzle-team/drizzle-orm")

# Get examples and best practices
get-library-docs("/drizzle-team/drizzle-orm", topic="examples")
```

## 📚 **Common Library Categories**

### **Frontend Frameworks:**

- `/vercel/next.js` - Next.js React framework
- `/facebook/react` - React library
- `/vuejs/vue` - Vue.js framework
- `/angular/angular` - Angular framework
- `/sveltejs/svelte` - Svelte framework

### **Backend Frameworks:**

- `/expressjs/express` - Express.js for Node.js
- `/nestjs/nest` - NestJS framework
- `/fastify/fastify` - Fastify web framework
- `/django/django` - Django Python framework
- `/flask/flask` - Flask Python framework

### **Databases & ORMs:**

- `/mongodb/docs` - MongoDB database
- `/postgres/postgres` - PostgreSQL database
- `/supabase/supabase` - Supabase platform
- `/prisma/prisma` - Prisma ORM
- `/drizzle-team/drizzle-orm` - Drizzle ORM

### **Development Tools:**

- `/microsoft/vscode` - VS Code editor
- `/typescript-eslint/typescript-eslint` - TypeScript ESLint
- `/prettier/prettier` - Code formatter
- `/vitejs/vite` - Vite build tool
- `/webpack/webpack` - Webpack bundler

### **AI/ML Tools:**

- `/openai/openai-node` - OpenAI Node.js SDK
- `/anthropic/anthropic-sdk-typescript` - Anthropic TypeScript SDK
- `/langchain-ai/langchainjs` - LangChain JavaScript
- `/huggingface/transformers.js` - Hugging Face Transformers

## 🛠️ **Best Practices**

### **Library Resolution:**

1. **Always resolve first**: Use `resolve-library-id` before `get-library-docs`
2. **Use specific names**: "next.js" is better than "nextjs"
3. **Check alternatives**: Some libraries have multiple valid IDs
4. **Cache results**: Store resolved IDs for repeated use

### **Documentation Retrieval:**

1. **Use topics**: Specify topics for focused results (`topic="routing"`)
2. **Manage tokens**: Adjust token limits based on detail needed
3. **Version-specific**: Use specific versions when working with older code
4. **Combine sources**: Get docs from multiple related libraries

### **Development Workflow:**

1. **Start with docs**: Get documentation before coding
2. **Reference during development**: Keep docs accessible while coding
3. **Check for updates**: Regularly verify you're using latest practices
4. **Validate approaches**: Use docs to verify your implementation approach

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Library Not Found:**

```bash
# Try different variations
resolve-library-id("nextjs")      # Try without dots
resolve-library-id("next")        # Try shortened name
resolve-library-id("vercel/next") # Try with org prefix
```

#### **Documentation Seems Outdated:**

```bash
# Check for specific version
get-library-docs("/vercel/next.js/v14.0.0")

# Verify library has moved or been renamed
resolve-library-id("new-library-name")
```

#### **MCP Server Not Responding:**

```bash
# Test the server directly
npx -y @context7/mcp-server@latest --version

# Check your AI assistant's MCP configuration
# Restart your AI assistant
```

## 🎯 **Integration with Your Workflow**

### **Project Setup:**

```bash
# Create project-specific library list
echo '["next.js", "tailwind", "prisma", "supabase"]' > .context7-libraries

# Get setup docs for all libraries
for lib in $(cat .context7-libraries); do
  resolve-library-id("$lib") && get-library-docs(result, topic="setup")
done
```

### **Code Review:**

- **Verify best practices** against latest documentation
- **Check for deprecated** APIs and patterns
- **Reference migration guides** for version updates
- **Validate security practices** with official guidelines

### **Learning & Development:**

- **Explore new libraries** with comprehensive documentation
- **Understand breaking changes** between versions
- **Learn best practices** from official examples
- **Stay updated** with latest features and improvements

## 🌟 **Advanced Features**

### **Version-Specific Documentation:**

```bash
# Get docs for specific version
get-library-docs("/vercel/next.js/v13.5.0")

# Compare between versions
get-library-docs("/react-router/react-router/v5.3.0")
get-library-docs("/react-router/react-router/v6.0.0")
```

### **Topic-Focused Queries:**

```bash
# Get specific topic documentation
get-library-docs("/vercel/next.js", topic="api-routes")
get-library-docs("/prisma/prisma", topic="migrations")
get-library-docs("/supabase/supabase", topic="authentication")
```

### **Token Management:**

```bash
# Brief overview (default: 5000 tokens)
get-library-docs("/facebook/react")

# Detailed documentation (more tokens)
get-library-docs("/facebook/react", tokens=15000)

# Quick reference (fewer tokens)
get-library-docs("/facebook/react", tokens=2000)
```

## 📈 **Benefits for Your Development**

✅ **Always Current** - Documentation is continuously updated
✅ **Version Aware** - Access docs for specific versions you're using
✅ **AI Optimized** - Content formatted for better AI understanding
✅ **Comprehensive** - Covers thousands of popular development tools
✅ **Fast Access** - Real-time retrieval without manual searching
✅ **Context Aware** - AI understands your specific development context

---

**Transform your AI-assisted development with real-time access to the latest documentation!** 🚀📚
