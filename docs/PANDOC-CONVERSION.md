# 🔄 Pandoc Document Conversion for AI DevOps

**Convert any document format to markdown for optimal AI assistant processing**

## 🎯 **Overview**

The Pandoc integration in AI DevOps Framework enables seamless conversion of various document formats to markdown, making them easily accessible and processable by AI assistants. This dramatically improves the ability to work with legacy documents, presentations, PDFs, and other formats.

## 📦 **Installation**

### **Install Pandoc**

```bash
# macOS
brew install pandoc poppler

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install pandoc poppler-utils

# CentOS/RHEL
sudo yum install pandoc poppler-utils

# Windows (Chocolatey)
choco install pandoc

# Windows (Scoop)
scoop install pandoc
```

### **Verify Installation**

```bash
pandoc --version
pdftotext -v  # For PDF support
```

## 🚀 **Quick Start**

### **Single File Conversion**

```bash
# Convert Word document to markdown
bash providers/pandoc-helper.sh convert document.docx

# Convert PDF with custom output name
bash providers/pandoc-helper.sh convert report.pdf analysis.md

# Convert with specific format and options
bash providers/pandoc-helper.sh convert file.html output.md html "--extract-media=./images"
```

### **Batch Conversion**

```bash
# Convert all Word documents in a directory
bash providers/pandoc-helper.sh batch ./documents ./markdown "*.docx"

# Convert all supported formats
bash providers/pandoc-helper.sh batch ./input ./output "*"

# Convert with specific pattern
bash providers/pandoc-helper.sh batch ./reports ./markdown "*.{pdf,docx,html}"
```

## 📄 **Supported Formats**

### **📋 Document Formats**
- **Microsoft Word**: `.docx`, `.doc`
- **PDF**: `.pdf` (requires pdftotext)
- **OpenDocument**: `.odt`
- **Rich Text**: `.rtf`
- **LaTeX**: `.tex`, `.latex`

### **🌐 Web & eBook Formats**
- **HTML**: `.html`, `.htm`
- **EPUB**: `.epub`
- **MediaWiki**: `.mediawiki`
- **TWiki**: `.twiki`

### **📊 Data Formats**
- **JSON**: `.json`
- **CSV**: `.csv`
- **TSV**: `.tsv`
- **XML**: `.xml`

### **📝 Markup Formats**
- **reStructuredText**: `.rst`
- **Org-mode**: `.org`
- **Textile**: `.textile`
- **OPML**: `.opml`

### **📊 Presentation Formats**
- **PowerPoint**: `.pptx`, `.ppt` (limited support)
- **Excel**: `.xlsx`, `.xls` (limited support)

## 🔧 **Advanced Usage**

### **Format Detection**

```bash
# Automatically detect file format
bash providers/pandoc-helper.sh detect unknown_file.ext

# Show all supported formats
bash providers/pandoc-helper.sh formats
```

### **Custom Conversion Options**

```bash
# Extract images and media
bash providers/pandoc-helper.sh convert document.docx output.md docx "--extract-media=./media"

# Include table of contents
bash providers/pandoc-helper.sh convert document.html output.md html "--toc"

# Create standalone document
bash providers/pandoc-helper.sh convert document.rst output.md rst "--standalone"

# Set custom metadata
bash providers/pandoc-helper.sh convert document.tex output.md latex "--metadata title='My Document'"
```

## 🤖 **AI Assistant Integration**

### **Why Convert to Markdown?**

1. **Consistent Formatting**: Standardized structure for AI processing
2. **Easy Parsing**: Simple syntax that AI can understand and manipulate
3. **Preserved Structure**: Maintains headings, lists, and formatting
4. **Lightweight**: Fast processing and analysis
5. **Version Control**: Git-friendly format for tracking changes
6. **Cross-Platform**: Works everywhere without special software

### **Optimal AI Workflows**

```bash
# 1. Convert documents for analysis
bash providers/pandoc-helper.sh batch ./project-docs ./markdown "*.{docx,pdf,html}"

# 2. Process converted files with AI
# AI can now easily read and analyze all documents

# 3. Generate summaries, extract information, or create new content
# Based on the converted markdown files
```

## 📊 **Configuration**

### **Default Settings**

The framework uses optimized settings for AI processing:

- **Output Format**: Markdown with ATX headers (`# ## ###`)
- **Line Wrapping**: None (preserves formatting)
- **Media Extraction**: Automatic for supported formats
- **Structure Preservation**: Maintains document hierarchy
- **Metadata Addition**: Includes source file information

### **Customization**

Edit `configs/pandoc-config.json` to customize:

```json
{
  "conversion_settings": {
    "default_output_format": "markdown",
    "wrap_mode": "none",
    "header_style": "atx",
    "include_toc": false,
    "extract_media": true
  }
}
```

## 🔍 **Quality Assurance**

### **Conversion Validation**

The helper script automatically:

- ✅ **Validates output**: Checks for successful conversion
- ✅ **Shows preview**: Displays first 10 lines of converted content
- ✅ **Reports metrics**: File size and line count
- ✅ **Error handling**: Clear error messages for failed conversions

### **Best Practices**

1. **Test conversions**: Always review output quality
2. **Backup originals**: Keep source files safe
3. **Check encoding**: Ensure proper character encoding
4. **Validate structure**: Verify headings and formatting
5. **Extract media**: Save images and attachments separately

## 🚨 **Troubleshooting**

### **Common Issues**

#### **PDF Conversion Problems**
```bash
# Install PDF support
brew install poppler          # macOS
sudo apt install poppler-utils # Ubuntu
```

#### **Encoding Issues**
```bash
# Specify input encoding
pandoc -f html -t markdown --from=html+smart input.html -o output.md
```

#### **Large File Processing**
```bash
# For large files, consider splitting or using specific options
pandoc --verbose input.pdf -o output.md
```

### **Format-Specific Notes**

- **PDF**: Quality depends on source document structure
- **PowerPoint**: Limited support, best for text content
- **Excel**: Basic table conversion only
- **HTML**: May need cleanup for complex layouts
- **Word**: Generally excellent conversion quality

## 📈 **Performance Tips**

1. **Batch Processing**: Convert multiple files at once
2. **Format Selection**: Use specific input formats when known
3. **Media Extraction**: Extract images to separate directory
4. **Parallel Processing**: Use multiple terminal sessions for large batches
5. **Cleanup**: Remove temporary files after conversion

## 🔗 **Integration Examples**

### **With AI Assistants**

```bash
# Convert project documentation
bash providers/pandoc-helper.sh batch ./docs ./ai-ready "*.{docx,pdf}"

# Now AI can process all documentation:
# "Analyze all the converted documentation and create a project summary"
# "Extract all requirements from the converted specifications"
# "Generate a comprehensive README from all the documentation"
```

### **With Version Control**

```bash
# Convert and commit to Git
bash providers/pandoc-helper.sh batch ./documents ./markdown
git add markdown/
git commit -m "📄 Add converted documentation for AI processing"
```

## 🌟 **Benefits for AI DevOps**

- **📚 Legacy Document Access**: Convert old formats for modern AI processing
- **🔄 Format Standardization**: Unified markdown format across all documents
- **🤖 AI Optimization**: Perfect format for AI analysis and manipulation
- **📊 Batch Processing**: Handle large document collections efficiently
- **🔍 Content Discovery**: Make all documents searchable and analyzable
- **📝 Documentation Modernization**: Update legacy docs to current standards

---

**Transform any document into AI-ready markdown with the AI DevOps Pandoc integration!** 🚀📄✨
