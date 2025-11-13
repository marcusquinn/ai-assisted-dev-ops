#!/bin/bash

# Pandoc Document Conversion Helper for AI DevOps Framework
# Converts various document formats to markdown for AI assistant processing
#
# Author: AI DevOps Framework
# Version: 1.1.2

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if pandoc is installed
check_pandoc() {
    if ! command -v pandoc &> /dev/null; then
        print_error "Pandoc is not installed. Please install it first:"
        echo ""
        echo "macOS:   brew install pandoc"
        echo "Ubuntu:  sudo apt-get install pandoc"
        echo "CentOS:  sudo yum install pandoc"
        echo "Windows: choco install pandoc"
        echo ""
        echo "Or download from: https://pandoc.org/installing.html"
        return 1
    fi
    return 0
}

# Function to detect file format
detect_format() {
    local file="$1"
    local extension="${file##*.}"
    
    case "$(echo "$extension" | tr '[:upper:]' '[:lower:]')" in
        "docx"|"doc") echo "docx" ;;
        "pdf") echo "pdf" ;;
        "html"|"htm") echo "html" ;;
        "epub") echo "epub" ;;
        "odt") echo "odt" ;;
        "rtf") echo "rtf" ;;
        "tex"|"latex") echo "latex" ;;
        "rst") echo "rst" ;;
        "org") echo "org" ;;
        "textile") echo "textile" ;;
        "mediawiki") echo "mediawiki" ;;
        "twiki") echo "twiki" ;;
        "opml") echo "opml" ;;
        "json") echo "json" ;;
        "csv") echo "csv" ;;
        "tsv") echo "tsv" ;;
        "xml") echo "xml" ;;
        "pptx"|"ppt") echo "pptx" ;;
        "xlsx"|"xls") echo "xlsx" ;;
        *) echo "unknown" ;;
    esac
}

# Function to convert single file to markdown
convert_to_markdown() {
    local input_file="$1"
    local output_file="$2"
    local input_format="$3"
    local options="$4"
    
    if [[ ! -f "$input_file" ]]; then
        print_error "Input file not found: $input_file"
        return 1
    fi
    
    # Auto-detect format if not specified
    if [[ -z "$input_format" || "$input_format" == "auto" ]]; then
        input_format=$(detect_format "$input_file")
        if [[ "$input_format" == "unknown" ]]; then
            print_warning "Could not detect format for $input_file, trying auto-detection"
            input_format=""
        fi
    fi
    
    # Set default output file if not specified
    if [[ -z "$output_file" ]]; then
        output_file="${input_file%.*}.md"
    fi
    
    # Build pandoc command
    local pandoc_cmd="pandoc"
    
    # Add input format if specified
    if [[ -n "$input_format" ]]; then
        pandoc_cmd="$pandoc_cmd -f $input_format"
    fi
    
    # Add output format (always markdown)
    pandoc_cmd="$pandoc_cmd -t markdown"
    
    # Add common options for better markdown output
    pandoc_cmd="$pandoc_cmd --wrap=none --markdown-headings=atx"
    
    # Add custom options if provided
    if [[ -n "$options" ]]; then
        pandoc_cmd="$pandoc_cmd $options"
    fi
    
    # Add input and output files
    pandoc_cmd="$pandoc_cmd \"$input_file\" -o \"$output_file\""
    
    print_info "Converting: $input_file → $output_file"
    print_info "Command: $pandoc_cmd"
    
    # Execute conversion
    if eval "$pandoc_cmd"; then
        print_success "Converted successfully: $output_file"
        
        # Show file size and preview
        local size=$(du -h "$output_file" | cut -f1)
        local lines=$(wc -l < "$output_file")
        print_info "Output: $size, $lines lines"
        
        # Show first few lines as preview
        echo ""
        echo "Preview (first 10 lines):"
        echo "------------------------"
        head -10 "$output_file"
        echo "------------------------"
        
        return 0
    else
        print_error "Conversion failed"
        return 1
    fi
}

# Function to convert multiple files in a directory
convert_directory() {
    local input_dir="$1"
    local output_dir="$2"
    local pattern="$3"
    local input_format="$4"
    local options="$5"
    
    if [[ ! -d "$input_dir" ]]; then
        print_error "Input directory not found: $input_dir"
        return 1
    fi
    
    # Create output directory if it doesn't exist
    if [[ -n "$output_dir" ]]; then
        mkdir -p "$output_dir"
    else
        output_dir="$input_dir/markdown"
        mkdir -p "$output_dir"
    fi
    
    # Set default pattern if not specified
    if [[ -z "$pattern" ]]; then
        pattern="*"
    fi
    
    print_info "Converting files in: $input_dir"
    print_info "Output directory: $output_dir"
    print_info "Pattern: $pattern"
    
    local count=0
    local success=0
    
    # Find and convert files
    while IFS= read -r -d '' file; do
        count=$((count + 1))
        local basename=$(basename "$file")
        local output_file="$output_dir/${basename%.*}.md"
        
        if convert_to_markdown "$file" "$output_file" "$input_format" "$options"; then
            success=$((success + 1))
        fi
        echo ""
    done < <(find "$input_dir" -maxdepth 1 -name "$pattern" -type f -print0)
    
    print_info "Conversion complete: $success/$count files converted successfully"
}

# Function to show supported formats
show_formats() {
    echo "Pandoc Document Conversion - Supported Formats"
    echo "=============================================="
    echo ""
    echo "📄 Document Formats:"
    echo "  • Microsoft Word: .docx, .doc"
    echo "  • PDF: .pdf (requires pdftotext)"
    echo "  • OpenDocument: .odt"
    echo "  • Rich Text: .rtf"
    echo "  • LaTeX: .tex, .latex"
    echo ""
    echo "🌐 Web Formats:"
    echo "  • HTML: .html, .htm"
    echo "  • EPUB: .epub"
    echo "  • MediaWiki: .mediawiki"
    echo "  • TWiki: .twiki"
    echo ""
    echo "📊 Data Formats:"
    echo "  • JSON: .json"
    echo "  • CSV: .csv"
    echo "  • TSV: .tsv"
    echo "  • XML: .xml"
    echo ""
    echo "📝 Markup Formats:"
    echo "  • reStructuredText: .rst"
    echo "  • Org-mode: .org"
    echo "  • Textile: .textile"
    echo "  • OPML: .opml"
    echo ""
    echo "📊 Presentation Formats:"
    echo "  • PowerPoint: .pptx, .ppt (limited support)"
    echo "  • Excel: .xlsx, .xls (limited support)"
    echo ""
    echo "For full format support, see: https://pandoc.org/MANUAL.html#general-options"
}

# Main function
main() {
    local action="$1"
    shift

    # Check if pandoc is installed
    if ! check_pandoc; then
        exit 1
    fi

    case "$action" in
        "convert"|"c")
            local input_file="$1"
            local output_file="$2"
            local input_format="$3"
            local options="$4"

            if [[ -z "$input_file" ]]; then
                print_error "Input file required. Usage: $0 convert <input_file> [output_file] [format] [options]"
                exit 1
            fi

            convert_to_markdown "$input_file" "$output_file" "$input_format" "$options"
            ;;
        "batch"|"b")
            local input_dir="$1"
            local output_dir="$2"
            local pattern="$3"
            local input_format="$4"
            local options="$5"

            if [[ -z "$input_dir" ]]; then
                print_error "Input directory required. Usage: $0 batch <input_dir> [output_dir] [pattern] [format] [options]"
                exit 1
            fi

            convert_directory "$input_dir" "$output_dir" "$pattern" "$input_format" "$options"
            ;;
        "formats"|"f")
            show_formats
            ;;
        "detect"|"d")
            local file="$1"
            if [[ -z "$file" ]]; then
                print_error "File required. Usage: $0 detect <file>"
                exit 1
            fi

            local format=$(detect_format "$file")
            echo "Detected format for '$file': $format"
            ;;
        "install"|"i")
            print_info "Pandoc installation instructions:"
            echo ""
            echo "macOS (Homebrew):"
            echo "  brew install pandoc"
            echo ""
            echo "macOS (MacPorts):"
            echo "  sudo port install pandoc"
            echo ""
            echo "Ubuntu/Debian:"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install pandoc"
            echo ""
            echo "CentOS/RHEL:"
            echo "  sudo yum install pandoc"
            echo ""
            echo "Windows (Chocolatey):"
            echo "  choco install pandoc"
            echo ""
            echo "Windows (Scoop):"
            echo "  scoop install pandoc"
            echo ""
            echo "Manual installation:"
            echo "  Download from: https://pandoc.org/installing.html"
            echo ""
            echo "Additional dependencies for PDF support:"
            echo "  macOS: brew install poppler"
            echo "  Ubuntu: sudo apt-get install poppler-utils"
            ;;
        *)
            echo "Pandoc Document Conversion Helper - AI DevOps Framework"
            echo ""
            echo "Usage: $0 [action] [options]"
            echo ""
            echo "Actions:"
            echo "  convert|c <input> [output] [format] [options]  Convert single file to markdown"
            echo "  batch|b <dir> [output_dir] [pattern] [format]  Convert multiple files"
            echo "  formats|f                                      Show supported formats"
            echo "  detect|d <file>                               Detect file format"
            echo "  install|i                                     Show installation instructions"
            echo ""
            echo "Examples:"
            echo "  $0 convert document.docx"
            echo "  $0 convert document.pdf document.md"
            echo "  $0 batch ./documents ./markdown '*.docx'"
            echo "  $0 detect presentation.pptx"
            echo "  $0 formats"
            echo ""
            echo "Common Options:"
            echo "  --extract-media=DIR    Extract images to directory"
            echo "  --standalone          Create standalone document"
            echo "  --toc                 Include table of contents"
            echo "  --metadata title='Title'  Set document metadata"
            echo ""
            echo "For more options: pandoc --help"
            ;;
    esac
}

main "$@"
