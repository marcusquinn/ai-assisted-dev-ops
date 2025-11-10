#!/bin/bash

# Localhost Development Helper Script
# Sets up local Docker apps with .local domains and SSL certificates

# Colors for output
# String literal constants
readonly ERROR_CONFIG_NOT_FOUND="$ERROR_CONFIG_NOT_FOUND"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Error message constants
readonly USAGE_PREFIX="Usage:"
readonly ERROR_UNKNOWN_COMMAND="Unknown command:"

print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# Configuration file
CONFIG_FILE="../configs/localhost-config.json"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND"
        print_info "Copy and customize: cp ../configs/localhost-config.json.txt $CONFIG_FILE"
        exit 1
    fi
    return 0
}

# Check required tools
check_requirements() {
    local missing_tools=()
    local optional_tools=()

    command -v docker >/dev/null 2>&1 || missing_tools+=("docker")
    command -v mkcert >/dev/null 2>&1 || missing_tools+=("mkcert")
    command -v dnsmasq >/dev/null 2>&1 || missing_tools+=("dnsmasq")

    # Check for LocalWP (optional)
    if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
        print_success "LocalWP found - WordPress development integration available"

        # Check for LocalWP MCP server
        if command -v mcp-local-wp >/dev/null 2>&1; then
            print_success "LocalWP MCP server found - AI database access available"
        else
            print_info "Install LocalWP MCP server: npm install -g @verygoodplugins/mcp-local-wp"

        # Check for Context7 MCP server
        if command -v npx >/dev/null 2>&1; then
            print_success "Context7 MCP server available via npx"
        else
            print_info "Install Node.js and npm for Context7 MCP server access"
        fi
        fi
    else
        optional_tools+=("LocalWP")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Install missing tools:"
        echo "  Docker: https://docs.docker.com/get-docker/"
        echo "  mkcert: brew install mkcert (macOS) or see https://github.com/FiloSottile/mkcert"
        echo "  dnsmasq: brew install dnsmasq (macOS) or sudo apt-get install dnsmasq (Linux)"
        return 1
    fi

    if [[ ${#optional_tools[@]} -gt 0 ]]; then
        print_info "Optional tools not found: ${optional_tools[*]}"
        echo "  LocalWP: https://localwp.com/ (for WordPress development)"
    fi

    return 0
}

# Setup local DNS resolution for .local domains
setup_local_dns() {
    print_info "Setting up local DNS resolution for .local domains..."
    
    # Check if dnsmasq is configured
    local dnsmasq_conf="/usr/local/etc/dnsmasq.conf"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        dnsmasq_conf="/etc/dnsmasq.conf"
    fi
    
    if [[ -f "$dnsmasq_conf" ]]; then
        if ! grep -q "address=/.local/127.0.0.1" "$dnsmasq_conf"; then
            print_info "Adding .local domain resolution to dnsmasq..."
            echo "address=/.local/127.0.0.1" | sudo tee -a "$dnsmasq_conf"
            
            # Restart dnsmasq
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sudo brew services restart dnsmasq
            else
                sudo systemctl restart dnsmasq
            fi
            
            print_success "dnsmasq configured for .local domains"
        else
            print_info "dnsmasq already configured for .local domains"
        fi
    else
        print_warning "dnsmasq configuration file not found"
        print_info "Manual setup required - see documentation"
    fi
    
    # Setup resolver for macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sudo mkdir -p /etc/resolver
        echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/local
        print_success "macOS resolver configured for .local domains"
    fi
    return 0
}

# Generate SSL certificate for local domain
generate_ssl_cert() {
    local domain="$1"
    
    if [[ -z "$domain" ]]; then
        print_error "Please specify a domain"
        return 1
    fi
    
    print_info "Generating SSL certificate for $domain..."
    
    # Create certs directory
    mkdir -p ~/.local-ssl-certs
    
    # Generate certificate with mkcert
    cd ~/.local-ssl-certs || exit
    mkcert "$domain" "*.$domain"
    
    if [[ $? -eq 0 ]]; then
        print_success "SSL certificate generated for $domain"
        print_info "Certificate files:"
        print_info "  - ~/.local-ssl-certs/$domain+1.pem (certificate)"
        print_info "  - ~/.local-ssl-certs/$domain+1-key.pem (private key)"
    else
        print_error "Failed to generate SSL certificate"
        return 1
    fi
    return 0
}
    return 0
    return 0

# List configured local apps
list_apps() {
    check_config
    print_info "Configured local development apps:"
    
    apps=$(jq -r '.apps | keys[]' "$CONFIG_FILE")
    for app in $apps; do
        domain=$(jq -r ".apps.$app.domain" "$CONFIG_FILE")
        port=$(jq -r ".apps.$app.port" "$CONFIG_FILE")
        ssl=$(jq -r ".apps.$app.ssl" "$CONFIG_FILE")
        description=$(jq -r ".apps.$app.description" "$CONFIG_FILE")
        
        ssl_status="HTTP"
        if [[ "$ssl" == "true" ]]; then
            ssl_status="HTTPS"
        fi
        
        echo "  - $app: $description"
        echo "    URL: $ssl_status://$domain (port $port)"
        echo ""
    return 0
    done
    return 0
}

# Setup reverse proxy with Traefik
setup_traefik() {
    print_info "Setting up Traefik reverse proxy for local development..."
    
    # Create Traefik configuration
    mkdir -p ~/.local-dev-proxy
    
    cat > ~/.local-dev-proxy/traefik.yml << 'EOF'
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

certificatesResolvers:
  local:
    acme:
      email: dev@localhost
      storage: acme.json
      keyType: EC256
EOF

    cat > ~/.local-dev-proxy/dynamic.yml << 'EOF'
tls:
  certificates:
    - certFile: /certs/localhost.pem
      keyFile: /certs/localhost-key.pem
EOF

    # Create docker-compose for Traefik
    cat > ~/.local-dev-proxy/docker-compose.yml << 'EOF'
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: local-traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"  # Traefik dashboard
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic.yml:/etc/traefik/dynamic.yml:ro
      - ~/.local-ssl-certs:/certs:ro
    networks:
      - local-dev

networks:
  local-dev:
    external: true
EOF

    # Create network
    docker network create local-dev 2>/dev/null || true
    
    # Start Traefik
    cd ~/.local-dev-proxy || exit
    docker-compose up -d
    return 0
    
    print_success "Traefik reverse proxy started"
    return 0
    print_info "Dashboard available at: http://localhost:8080"
    return 0
}

# List LocalWP sites
list_localwp_sites() {
    print_info "Checking for LocalWP sites..."

    local localwp_path="$HOME/Local Sites"
    if [[ -d "$localwp_path" ]]; then
        print_success "LocalWP sites found:"
        for site_dir in "$localwp_path"/*; do
            if [[ -d "$site_dir" ]]; then
                local site_name=$(basename "$site_dir")
                local conf_file="$site_dir/conf/nginx/site.conf"
                if [[ -f "$conf_file" ]]; then
                    local port=$(grep -o 'listen [0-9]*' "$conf_file" | head -1 | awk '{print $param2}')
                    echo "  - $site_name (http://localhost:$port)"
                else
                    echo "  - $site_name (configuration not found)"
                fi
            fi
        done
    else
        print_warning "LocalWP sites directory not found at: $localwp_path"
        print_info "Install LocalWP from: https://localwp.com/"
    fi
    return 0
}

# Create LocalWP-compatible .local domain
setup_localwp_domain() {
    local site_name="$1"
    local custom_domain="$param2"

    if [[ -z "$site_name" ]]; then
        print_error "Usage: setup-localwp-domain [site-name] [custom-domain.local]"
        return 1
    fi

    local localwp_path="$HOME/Local Sites/$site_name"
    if [[ ! -d "$localwp_path" ]]; then
        print_error "LocalWP site not found: $site_name"
        print_info "Available sites:"
        list_localwp_sites
        return 1
    fi

    local domain="${custom_domain:-$site_name.local}"
    local conf_file="$localwp_path/conf/nginx/site.conf"

    if [[ -f "$conf_file" ]]; then
        local port=$(grep -o 'listen [0-9]*' "$conf_file" | head -1 | awk '{print $param2}')
        print_info "Setting up $domain for LocalWP site $site_name (port $port)"

        # Generate SSL certificate
        generate_ssl_cert "$domain"

        # Add to Traefik configuration
        setup_localwp_traefik "$site_name" "$domain" "$port"
    return 0

        print_success "LocalWP site $site_name now available at: https://$domain"
    else
    return 0
        print_error "LocalWP configuration not found for: $site_name"
    fi
    return 0
}

# Setup Traefik for LocalWP site
setup_localwp_traefik() {
    local site_name="$1"
    local domain="$param2"
    local port="$param3"

    # Create Traefik configuration for LocalWP site
    mkdir -p ~/.local-dev-proxy/localwp

    cat > ~/.local-dev-proxy/localwp/"$site_name".yml << EOF
http:
  routers:
    localwp-$site_name:
      rule: "Host(\`$domain\`)"
      tls: true
      service: localwp-$site_name-service
      entryPoints:
        - websecure

  services:
    localwp-$site_name-service:
      loadBalancer:
        servers:
          - url: "http://localhost:$port"
EOF

    print_success "Traefik configuration created for $site_name"
    return 0
}

# Create Docker app with .local domain
create_app() {
    local app_name="$1"
    local domain="$param2"
    local port="$param3"
    local ssl="${4:-true}"
    local app_type="${5:-docker}"

    if [[ -z "$app_name" || -z "$domain" || -z "$port" ]]; then
        print_error "Usage: create-app [app-name] [domain.local] [port] [ssl:true/false] [type:docker/localwp]"
        return 1
    fi

    print_info "Creating local app: $app_name at $domain:$port (type: $app_type)"

    # Generate SSL certificate if needed
    if [[ "$ssl" == "true" ]]; then
        generate_ssl_cert "$domain"
    fi

    if [[ "$app_type" == "localwp" ]]; then
        setup_localwp_domain "$app_name" "$domain"
        return $?
    fi

    # Create app directory
    mkdir -p ~/.local-apps/"$app_name"

    # Create sample docker-compose with Traefik labels
    cat > ~/.local-apps/"$app_name"/docker-compose.yml << EOF
version: '3.8'

services:
  $app_name:
    image: nginx:alpine
    container_name: $app_name
    restart: unless-stopped
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.$app_name.rule=Host(\`$domain\`)"
      - "traefik.http.services.$app_name.loadbalancer.server.port=$port"
EOF

    if [[ "$ssl" == "true" ]]; then
        cat >> ~/.local-apps/"$app_name"/docker-compose.yml << EOF
      - "traefik.http.routers.$app_name.tls=true"
      - "traefik.http.routers.$app_name.entrypoints=websecure"
EOF
    else
        cat >> ~/.local-apps/"$app_name"/docker-compose.yml << EOF
      - "traefik.http.routers.$app_name.entrypoints=web"
EOF
    fi

    cat >> ~/.local-apps/"$app_name"/docker-compose.yml << EOF
    networks:
      - local-dev

networks:
  local-dev:
    external: true
EOF

    print_success "App configuration created at ~/.local-apps/$app_name/"

    if [[ "$ssl" == "true" ]]; then
        print_info "Access your app at: https://$domain"
    else
        print_info "Access your app at: http://$domain"
    fi
    return 0
}

# Start LocalWP MCP server
start_localwp_mcp() {
    print_info "Starting LocalWP MCP server..."

    if ! command -v mcp-local-wp >/dev/null 2>&1; then
        print_error "LocalWP MCP server not installed"
        print_info "Install with: npm install -g @verygoodplugins/mcp-local-wp"
        return 1
    fi

    # Check if LocalWP is running
    if ! pgrep -f "Local" >/dev/null 2>&1; then
        print_warning "Local by Flywheel doesn't appear to be running"
        print_info "Start Local by Flywheel and ensure a site is active"
    fi

    print_info "Starting MCP server on port 8085..."
    mcp-local-wp --transport sse --port 8085 &
    local mcp_pid=$!

    sleep 2
    if kill -0 "$mcp_pid" 2>/dev/null; then
        print_success "LocalWP MCP server started (PID: $mcp_pid)"
        print_info "AI assistants can now access your WordPress database"
        print_info "Available tools: mysql_query, mysql_schema"
        return 0
    else
        print_error "Failed to start LocalWP MCP server"
        return 1
    fi
    return 0
}

# Stop LocalWP MCP server
stop_localwp_mcp() {
    print_info "Stopping LocalWP MCP server..."

    local pids=$(pgrep -f "mcp-local-wp")
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill
        print_success "LocalWP MCP server stopped"
    else
        print_info "LocalWP MCP server not running"
    fi
    return 0
}

# Main command handler
# Assign positional parameters to local variables
    local command="$1"
    local param2="$param2"
    local param3="$param3"
    
    case "$command" in
    "setup-dns")
        check_requirements && setup_local_dns
        ;;
    "setup-proxy")
        check_requirements && setup_traefik
        ;;
    "generate-cert")
        generate_ssl_cert "$param2"
        ;;
    "list")
        list_apps
        ;;
    "create-app")
        create_app "$param2" "$param3" "$param4" "$param5" "$param6"
        ;;
    "list-localwp")
        list_localwp_sites
        ;;
    "setup-localwp-domain")
        setup_localwp_domain "$param2" "$param3"
        ;;
    "start-mcp")
        start_localwp_mcp
        ;;
    "stop-mcp")
        stop_localwp_mcp
        ;;
    "help"|"-h"|"--help"|"")
        echo "Localhost Development Helper Script"
        echo "$USAGE_COMMAND_OPTIONS"
        echo ""
        echo "DNS & Proxy Commands:"
        echo "  setup-dns                           - Setup local DNS resolution for .local domains"
        echo "  setup-proxy                         - Setup Traefik reverse proxy"
        echo "  generate-cert [domain]              - Generate SSL certificate for domain"
        echo ""
        echo "App Management Commands:"
        echo "  list                                - List configured local apps"
        echo "  create-app [name] [domain] [port] [ssl] [type] - Create new local app"
        echo ""
        echo "LocalWP Integration Commands:"
        echo "  list-localwp                        - List LocalWP sites"
        echo "  setup-localwp-domain [site] [domain] - Setup .local domain for LocalWP site"
        echo "  start-mcp                           - Start LocalWP MCP server for AI database access"
        echo "  stop-mcp                            - Stop LocalWP MCP server"
        echo ""
        echo "Examples:"
        echo "  $0 setup-dns"
        echo "  $0 setup-proxy"
        echo "  $0 generate-cert myapp.local"
        echo "  $0 create-app myapp myapp.local 3000 true docker"
        echo "  $0 list-localwp"
        echo "  $0 setup-localwp-domain plugin-testing plugin-testing.local"
        echo "  $0 start-mcp"
        echo "  $0 stop-mcp"
        echo ""
        echo "Requirements:"
        echo "  - Docker and Docker Compose"
        echo "  - mkcert for SSL certificates"
        echo "  - dnsmasq for local DNS resolution"
        echo "  - LocalWP (optional, for WordPress development)"
        echo "  - @verygoodplugins/mcp-local-wp (optional, for AI database access)"
        ;;
    *)
        print_error "$ERROR_UNKNOWN_COMMAND $command"
        print_info "$HELP_USAGE_INFO"
        exit 1
        ;;
esac
