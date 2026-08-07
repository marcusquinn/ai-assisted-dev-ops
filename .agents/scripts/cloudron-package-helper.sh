#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cloudron-package-helper.sh - Cloudron app packaging development workflow
# Usage: cloudron-package-helper.sh [command] [args]
#
# Commands:
#   init [name]           Initialize new Cloudron app package
#   validate              Validate CloudronManifest.json
#   build                 Build Docker image
#   install [location]    Install app on Cloudron
#   update                Update installed app
#   logs [app]            View app logs
#   exec [app]            Shell into app container
#   debug [app]           Enable debug mode
#   debug-off [app]       Disable debug mode
#   test [app]            Run validation checklist
#   scaffold [type]       Generate boilerplate (php|node|python|go|static|multi-process)
#   prepare-release       Update manifest/changelog without publishing
#   check-release         Validate manifest/changelog/tag release invariants
#   check-compatibility   Audit manifest and final Cloudron base image
#   status                Show current package status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=cloudron-package-release-lib.sh
source "${SCRIPT_DIR}/cloudron-package-release-lib.sh"

set -euo pipefail

# Logging: uses shared log_* from shared-constants.sh
# Override log_error to return non-zero so error chains remain detectable.
log_error() {
	local label="${LOG_PREFIX:+${LOG_PREFIX}}"
	echo -e "${RED}[${label:-ERROR}]${NC} $*" >&2
	return 1
}

# Check if cloudron CLI is installed
check_cloudron_cli() {
	if ! command -v cloudron &>/dev/null; then
		log_error "Cloudron CLI not found. Install with: npm install -g cloudron"
		return 1
	fi
	return 0
}

# Check if we're in a Cloudron app directory
check_app_dir() {
	if [[ ! -f "CloudronManifest.json" ]]; then
		log_error "CloudronManifest.json not found. Are you in a Cloudron app directory?"
		return 1
	fi
	return 0
}

# Check if jq is installed
check_jq() {
	if ! command -v jq &>/dev/null; then
		log_error "jq not found. Install with: brew install jq (macOS) or apt-get install jq (Linux)"
		return 1
	fi
	return 0
}

# Write start.sh template for a generic Cloudron app
_init_create_start_sh() {
	cat >start.sh <<'STARTSH'
#!/bin/bash
set -eu

echo "==> Starting Cloudron App"

# First-run detection
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
    echo "==> First run detected"
else
    FIRST_RUN=false
fi

# Create directories
mkdir -p /app/data/config /app/data/storage /app/data/logs
mkdir -p /run/app

# First-run initialization
if [[ "$FIRST_RUN" == "true" ]]; then
    echo "==> Copying default configs"
    cp -rn /app/code/defaults/* /app/data/ 2>/dev/null || true
fi

# Fix permissions
chown -R cloudron:cloudron /app/data /run/app

# Mark initialized
touch /app/data/.initialized

# Launch application (replace with your command)
echo "==> Launching application"
exec gosu cloudron:cloudron echo "Replace this with your app start command"
STARTSH
	chmod +x start.sh
	log_success "Created start.sh template"
	return 0
}

# Write Dockerfile template for a generic Cloudron app
_init_create_dockerfile() {
	cat >Dockerfile <<'DOCKERFILE'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Add your dependencies here \
    && rm -rf /var/lib/apt/lists/*

# Copy application code
WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

# Preserve defaults for first-run
RUN mkdir -p /app/code/defaults

# Add start script
COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8000

CMD ["/app/code/start.sh"]
DOCKERFILE
	log_success "Created Dockerfile template"
	return 0
}

# Write .gitignore template for a Cloudron app project
_init_create_gitignore() {
	cat >.gitignore <<'GITIGNORE'
# Cloudron
.cloudron/

# aidevops
.agents/loop-state/
*.local.md

# Build artifacts
node_modules/
vendor/
dist/
__pycache__/
*.pyc
GITIGNORE
	log_success "Created .gitignore"
	return 0
}

# Initialize new Cloudron app package
cmd_init() {
	local name="${1:-}"

	check_cloudron_cli || return 1

	if [[ -n "$name" ]]; then
		mkdir -p "$name"
		cd "$name" || exit
		log_info "Created directory: $name"
	fi

	if [[ -f "CloudronManifest.json" ]]; then
		log_warn "CloudronManifest.json already exists"
		read -rp "Overwrite? [y/N] " confirm
		[[ "$confirm" != "y" && "$confirm" != "Y" ]] && return 0
	fi

	cloudron init

	[[ ! -f "start.sh" ]] && _init_create_start_sh
	[[ ! -f "Dockerfile" ]] && _init_create_dockerfile
	[[ ! -f ".gitignore" ]] && _init_create_gitignore

	log_success "Cloudron app package initialized"
	log_info "Next steps:"
	echo "  1. Edit CloudronManifest.json with your app details"
	echo "  2. Edit Dockerfile to install your app"
	echo "  3. Edit start.sh with your startup logic"
	echo "  4. Run: cloudron-package-helper.sh build"
	echo "  5. Run: cloudron-package-helper.sh install testapp"
	return 0
}

# Validate CloudronManifest.json
cmd_validate() {
	check_app_dir || return 1
	check_jq || return 1

	log_info "Validating CloudronManifest.json..."

	local errors=0
	local manifest
	manifest=$(cat CloudronManifest.json)

	# Check required fields
	local required_fields=("id" "title" "version" "healthCheckPath" "httpPort" "manifestVersion")
	for field in "${required_fields[@]}"; do
		if ! echo "$manifest" | jq -e ".$field" >/dev/null 2>&1; then
			log_error "Missing required field: $field"
			errors=$((errors + 1))
		fi
	done

	# Check manifestVersion
	local manifest_version
	manifest_version=$(echo "$manifest" | jq -r '.manifestVersion // 0')
	if [[ "$manifest_version" != "2" ]]; then
		log_error "manifestVersion must be 2 (got: $manifest_version)"
		errors=$((errors + 1))
	fi

	# Check httpPort is a number
	local http_port
	http_port=$(echo "$manifest" | jq -r '.httpPort // "null"')
	if ! [[ "$http_port" =~ ^[0-9]+$ ]]; then
		log_error "httpPort must be a positive integer"
		errors=$((errors + 1))
	fi

	# Check localstorage addon if app likely needs persistence
	if ! echo "$manifest" | jq -e '.addons.localstorage' >/dev/null 2>&1; then
		log_warn "localstorage addon not declared - app won't have persistent storage"
	fi

	# Check for icon
	if [[ ! -f "logo.png" ]] && [[ ! -f "icon.png" ]]; then
		log_warn "No logo.png or icon.png found (recommended: 256x256)"
	fi

	# Check start.sh exists and is executable
	if [[ ! -f "start.sh" ]]; then
		log_error "start.sh not found"
		errors=$((errors + 1))
	elif [[ ! -x "start.sh" ]]; then
		log_warn "start.sh is not executable (run: chmod +x start.sh)"
	fi

	# Check Dockerfile exists
	if [[ ! -f "Dockerfile" ]] && [[ ! -f "Dockerfile.cloudron" ]]; then
		log_error "Dockerfile not found"
		errors=$((errors + 1))
	fi

	if [[ $errors -eq 0 ]]; then
		log_success "Validation passed"
		return 0
	else
		log_error "Validation failed with $errors error(s)"
		return 1
	fi
}

# Build Docker image
cmd_build() {
	check_cloudron_cli || return 1
	check_app_dir || return 1

	log_info "Building Cloudron app..."
	cloudron build
	log_success "Build complete"
}

# Install app on Cloudron
cmd_install() {
	local location="${1:-}"

	check_cloudron_cli || return 1
	check_app_dir || return 1

	if [[ -z "$location" ]]; then
		log_error "Usage: cloudron-package-helper.sh install <location>"
		log_info "Example: cloudron-package-helper.sh install testapp"
		return 1
	fi

	log_info "Installing app at location: $location"
	cloudron install --location "$location"
	log_success "App installed at $location"
}

# Update installed app
cmd_update() {
	local app="${1:-}"

	check_cloudron_cli || return 1
	check_app_dir || return 1

	log_info "Building and updating app..."
	cloudron build

	if [[ -n "$app" ]]; then
		cloudron update --app "$app"
	else
		cloudron update
	fi
	log_success "App updated"
}

# View app logs
cmd_logs() {
	local app="${1:-}"

	check_cloudron_cli || return 1

	if [[ -n "$app" ]]; then
		cloudron logs -f --app "$app"
	else
		cloudron logs -f
	fi
}

# Shell into app container
cmd_exec() {
	local app="${1:-}"

	check_cloudron_cli || return 1

	if [[ -n "$app" ]]; then
		cloudron exec --app "$app"
	else
		cloudron exec
	fi
}

# Enable debug mode
cmd_debug() {
	local app="${1:-}"

	check_cloudron_cli || return 1

	log_info "Enabling debug mode (filesystem becomes writable, app paused)"
	if [[ -n "$app" ]]; then
		cloudron debug --app "$app"
	else
		cloudron debug
	fi
	log_success "Debug mode enabled. Use 'cloudron exec' to access container"
}

# Disable debug mode
cmd_debug_off() {
	local app="${1:-}"

	check_cloudron_cli || return 1

	log_info "Disabling debug mode"
	if [[ -n "$app" ]]; then
		cloudron debug --disable --app "$app"
	else
		cloudron debug --disable
	fi
	log_success "Debug mode disabled"
}

# Run validation checklist
cmd_test() {
	# Note: app parameter reserved for future use (specific app testing)

	check_cloudron_cli || return 1

	log_info "Running validation checklist..."
	echo ""
	echo "Manual Validation Checklist:"
	echo "============================"
	echo ""
	echo "[ ] Fresh install completes without errors"
	echo "    cloudron install --location testapp"
	echo ""
	echo "[ ] App survives restart"
	echo "    cloudron restart --app testapp"
	echo ""
	echo "[ ] Health check returns 200"
	echo "    curl -v https://testapp.yourdomain.com/health"
	echo ""
	echo "[ ] File uploads persist across restarts"
	echo "    (upload file, restart, verify file exists)"
	echo ""
	echo "[ ] Database connections work"
	echo "    cloudron exec --app testapp"
	echo "    env | grep CLOUDRON"
	echo ""
	echo "[ ] Email sending works (if applicable)"
	echo ""
	echo "[ ] Memory stays within limit"
	echo "    cloudron logs --app testapp | grep -i memory"
	echo ""
	echo "[ ] Upgrade from previous version works"
	echo "    cloudron update --app testapp"
	echo ""
	echo "[ ] Backup/restore cycle works"
	echo "    (create backup, restore, verify)"
	echo ""
	echo "[ ] Auto-updater is disabled"
	echo "    (check app settings)"
	echo ""
	echo "[ ] Logs stream to stdout/stderr"
	echo "    cloudron logs -f --app testapp"
	echo ""
}

# Generate boilerplate for specific app types
cmd_scaffold() {
	local app_type="${1:-}"

	case "$app_type" in
	php)
		scaffold_php
		;;
	node)
		scaffold_node
		;;
	python)
		scaffold_python
		;;
	go)
		scaffold_go
		;;
	static)
		scaffold_static
		;;
	multi-process)
		scaffold_multi_process
		;;
	*)
		log_error "Usage: cloudron-package-helper.sh scaffold <type>"
		echo "Types: php, node, python, go, static, multi-process"
		return 1
		;;
	esac
}

scaffold_php() {
	log_info "Generating PHP app scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" ]]; then
		log_warn "This will overwrite existing Dockerfile and start.sh"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	cat >Dockerfile <<'EOF'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    php8.2-fpm \
    php8.2-mysql \
    php8.2-pgsql \
    php8.2-curl \
    php8.2-gd \
    php8.2-mbstring \
    php8.2-xml \
    php8.2-zip \
    && rm -rf /var/lib/apt/lists/*

# Fix PHP session path
RUN rm -rf /var/lib/php/sessions && \
    ln -s /run/php/sessions /var/lib/php/sessions

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

# Preserve defaults
RUN mkdir -p /app/code/defaults && \
    mv /app/code/config /app/code/defaults/config 2>/dev/null || true && \
    mv /app/code/storage /app/code/defaults/storage 2>/dev/null || true

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF

	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting PHP App"

# First-run detection
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
    echo "==> First run detected"
else
    FIRST_RUN=false
fi

# Create directories
mkdir -p /app/data/config /app/data/storage /app/data/logs
mkdir -p /run/php/sessions /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi

# Symlinks
ln -sfn /app/data/config /app/code/config
ln -sfn /app/data/storage /app/code/storage

# First-run initialization
if [[ "$FIRST_RUN" == "true" ]]; then
    cp -rn /app/code/defaults/config/* /app/data/config/ 2>/dev/null || true
    cp -rn /app/code/defaults/storage/* /app/data/storage/ 2>/dev/null || true
fi

# Fix permissions
chown -R www-data:www-data /app/data /run/php /run/nginx

touch /app/data/.initialized

# Start PHP-FPM
php-fpm8.2 -D

# Start nginx
echo "==> Starting nginx"
exec nginx -g "daemon off;"
EOF
	chmod +x start.sh

	log_success "PHP scaffold created"
}

scaffold_node() {
	log_info "Generating Node.js app scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" ]]; then
		log_warn "This will overwrite existing Dockerfile and start.sh"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	cat >Dockerfile <<'EOF'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY package*.json ./
RUN npm ci --production && npm cache clean --force

COPY --chown=cloudron:cloudron . /app/code/

RUN mkdir -p /app/code/defaults

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

ENV NODE_ENV=production

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF

	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting Node.js App"

if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
else
    FIRST_RUN=false
fi

mkdir -p /app/data/config /app/data/storage
mkdir -p /run/app

if [[ "$FIRST_RUN" == "true" ]]; then
    cp -rn /app/code/defaults/* /app/data/ 2>/dev/null || true
fi

chown -R cloudron:cloudron /app/data /run/app
touch /app/data/.initialized

echo "==> Launching Node.js"
exec gosu cloudron:cloudron node /app/code/server.js
EOF
	chmod +x start.sh

	log_success "Node.js scaffold created"
}

scaffold_python() {
	log_info "Generating Python app scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" ]]; then
		log_warn "This will overwrite existing Dockerfile and start.sh"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	cat >Dockerfile <<'EOF'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY requirements.txt ./
RUN pip3 install --no-cache-dir -r requirements.txt

COPY --chown=cloudron:cloudron . /app/code/

RUN mkdir -p /app/code/defaults

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF

	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting Python App"

if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
else
    FIRST_RUN=false
fi

mkdir -p /app/data/config /app/data/storage
mkdir -p /run/app

if [[ "$FIRST_RUN" == "true" ]]; then
    cp -rn /app/code/defaults/* /app/data/ 2>/dev/null || true
fi

chown -R cloudron:cloudron /app/data /run/app
touch /app/data/.initialized

echo "==> Launching Python"
exec gosu cloudron:cloudron python3 /app/code/app.py
EOF
	chmod +x start.sh

	# Create empty requirements.txt
	touch requirements.txt

	log_success "Python scaffold created"
}

scaffold_go() {
	log_info "Generating Go app scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" ]]; then
		log_warn "This will overwrite existing Dockerfile and start.sh"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	cat >Dockerfile <<'EOF'
FROM golang:1.23 AS builder

WORKDIR /build
COPY go.* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o app .

FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

WORKDIR /app/code
COPY --from=builder /build/app /app/code/app

RUN mkdir -p /app/code/defaults

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF

	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting Go App"

if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
else
    FIRST_RUN=false
fi

mkdir -p /app/data/config /app/data/storage

if [[ "$FIRST_RUN" == "true" ]]; then
    cp -rn /app/code/defaults/* /app/data/ 2>/dev/null || true
fi

chown -R cloudron:cloudron /app/data
touch /app/data/.initialized

echo "==> Launching Go binary"
exec gosu cloudron:cloudron /app/code/app
EOF
	chmod +x start.sh

	log_success "Go scaffold created"
}

scaffold_static() {
	log_info "Generating static site scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" ]]; then
		log_warn "This will overwrite existing Dockerfile and start.sh"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	cat >Dockerfile <<'EOF'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

COPY nginx.conf /etc/nginx/sites-available/app.conf
RUN ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf && \
    rm -f /etc/nginx/sites-enabled/default

COPY start.sh /app/code/start.sh
RUN chmod +x /app/code/start.sh

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF

	cat >nginx.conf <<'EOF'
client_body_temp_path /run/nginx/client_body;
proxy_temp_path /run/nginx/proxy;
fastcgi_temp_path /run/nginx/fastcgi;

server {
    listen 8000;
    root /app/code/public;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF

	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting Static Site"

mkdir -p /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi

echo "==> Starting nginx"
exec nginx -g "daemon off;"
EOF
	chmod +x start.sh

	mkdir -p public
	echo "<h1>Hello from Cloudron!</h1>" >public/index.html

	log_success "Static site scaffold created"
}

# Write Dockerfile for a multi-process (supervisord) Cloudron app
_scaffold_multi_process_dockerfile() {
	cat >Dockerfile <<'EOF'
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/code
COPY --chown=cloudron:cloudron . /app/code/

RUN mkdir -p /app/code/defaults

# Nginx config
COPY nginx.conf /etc/nginx/sites-available/app.conf
RUN ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf && \
    rm -f /etc/nginx/sites-enabled/default

COPY start.sh /app/code/start.sh
COPY supervisord.conf /app/code/supervisord.conf
RUN chmod +x /app/code/start.sh

EXPOSE 8000

CMD ["/app/code/start.sh"]
EOF
	return 0
}

# Write supervisord.conf for a multi-process Cloudron app
_scaffold_multi_process_supervisord() {
	cat >supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:app]
command=/usr/local/bin/gosu cloudron:cloudron /app/code/bin/server
directory=/app/code
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:worker]
command=/usr/local/bin/gosu cloudron:cloudron /app/code/bin/worker
directory=/app/code
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
	return 0
}

# Write nginx.conf for a multi-process Cloudron app (proxy + health check)
_scaffold_multi_process_nginx() {
	cat >nginx.conf <<'EOF'
client_body_temp_path /run/nginx/client_body;
proxy_temp_path /run/nginx/proxy;
fastcgi_temp_path /run/nginx/fastcgi;
scgi_temp_path /run/nginx/scgi;
uwsgi_temp_path /run/nginx/uwsgi;

server {
    listen 8000;

    client_max_body_size 128m;

    # Immediate health check (responds before upstream is ready)
    location = /health {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF
	return 0
}

# Write start.sh for a multi-process Cloudron app (supervisord launcher)
_scaffold_multi_process_start_sh() {
	cat >start.sh <<'EOF'
#!/bin/bash
set -eu

echo "==> Starting Multi-Process App"

# First-run detection
if [[ ! -f /app/data/.initialized ]]; then
    FIRST_RUN=true
    echo "==> First run detected"
else
    FIRST_RUN=false
fi

# Create directories
mkdir -p /app/data/config /app/data/storage /app/data/logs
mkdir -p /run/app /run/nginx/client_body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/scgi /run/nginx/uwsgi

# First-run initialization
if [[ "$FIRST_RUN" == "true" ]]; then
    echo "==> Copying default configs"
    cp -rn /app/code/defaults/* /app/data/ 2>/dev/null || true
fi

# Fix permissions
chown -R cloudron:cloudron /app/data /run/app

touch /app/data/.initialized

# Launch all processes via supervisord
echo "==> Starting supervisord"
exec /usr/bin/supervisord --configuration /app/code/supervisord.conf
EOF
	chmod +x start.sh
	return 0
}

scaffold_multi_process() {
	log_info "Generating multi-process (supervisord) scaffold..."

	# Check for existing files
	if [[ -f "Dockerfile" || -f "start.sh" || -f "supervisord.conf" || -f "nginx.conf" ]]; then
		log_warn "This will overwrite existing Dockerfile, start.sh, supervisord.conf, and nginx.conf"
		read -rp "Continue? [y/N] " confirm
		if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
			log_info "Scaffold cancelled."
			return 0
		fi
	fi

	_scaffold_multi_process_dockerfile
	_scaffold_multi_process_supervisord
	_scaffold_multi_process_nginx
	_scaffold_multi_process_start_sh

	log_success "Multi-process scaffold created (nginx + app + worker via supervisord)"
	log_info "Edit supervisord.conf to configure your app and worker commands"
	log_info "The nginx health check at /health responds immediately (before app is ready)"
	return 0
}

# Show current package status
cmd_status() {
	check_app_dir || return 1
	check_jq || return 1

	log_info "Package Status"
	echo ""

	# Read manifest
	local manifest
	manifest=$(cat CloudronManifest.json)

	echo "App ID:      $(echo "$manifest" | jq -r '.id // "not set"')"
	echo "Title:       $(echo "$manifest" | jq -r '.title // "not set"')"
	echo "Version:     $(echo "$manifest" | jq -r '.version // "not set"')"
	echo "HTTP Port:   $(echo "$manifest" | jq -r '.httpPort // "not set"')"
	echo "Health Path: $(echo "$manifest" | jq -r '.healthCheckPath // "not set"')"
	echo ""

	echo "Addons:"
	echo "$manifest" | jq -r '.addons // {} | keys[]' | while read -r addon; do
		echo "  - $addon"
	done
	echo ""

	echo "Files:"
	[[ -f "Dockerfile" ]] && echo "  [x] Dockerfile" || echo "  [ ] Dockerfile"
	[[ -f "Dockerfile.cloudron" ]] && echo "  [x] Dockerfile.cloudron"
	[[ -f "start.sh" ]] && echo "  [x] start.sh" || echo "  [ ] start.sh"
	[[ -f "logo.png" ]] && echo "  [x] logo.png" || echo "  [ ] logo.png (recommended)"
	echo ""
	return 0
}

cmd_prepare_release() {
	cloudron_package_prepare_release "$@"
	return $?
}

cmd_check_release() {
	cloudron_package_check_release "$@"
	return $?
}

cmd_check_compatibility() {
	local findings=""
	if findings=$(cloudron_package_compatibility_findings "."); then
		printf 'Cloudron package compatibility validation passed.\n'
		return 0
	fi
	printf '%s\n' "$findings" >&2
	return 1
}

# Show help
show_help() {
	cat <<'HELP'
Cloudron App Packaging Helper

Usage: cloudron-package-helper.sh [command] [args]

Commands:
  init [name]           Initialize new Cloudron app package
  validate              Validate CloudronManifest.json
  build                 Build Docker image
  install <location>    Install app on Cloudron
  update [app]          Build and update installed app
  logs [app]            View app logs (follows)
  exec [app]            Shell into app container
  debug [app]           Enable debug mode
  debug-off [app]       Disable debug mode
  test [app]            Show validation checklist
  scaffold <type>       Generate boilerplate (php|node|python|go|static|multi-process)
  prepare-release <package-version> <upstream-version> <notes-file>
                        Update manifest/changelog without publishing
  check-release <tag>   Validate package, changelog, and vX.Y.Z tag
  check-compatibility   Audit manifest and final pinned Cloudron base image
  status                Show current package status
  help                  Show this help

Examples:
  cloudron-package-helper.sh init myapp
  cloudron-package-helper.sh scaffold php
  cloudron-package-helper.sh validate
  cloudron-package-helper.sh build
  cloudron-package-helper.sh install testapp
  cloudron-package-helper.sh update
  cloudron-package-helper.sh logs testapp
  cloudron-package-helper.sh prepare-release 1.2.0 4.5.6 release-notes.md
  cloudron-package-helper.sh check-release v1.2.0

Documentation:
  https://docs.cloudron.io/packaging/
  https://forum.cloudron.io/category/96/app-packaging-development
HELP
	return 0
}

# Main entry point
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	init)
		cmd_init "$@"
		;;
	validate)
		cmd_validate "$@"
		;;
	build)
		cmd_build "$@"
		;;
	install)
		cmd_install "$@"
		;;
	update)
		cmd_update "$@"
		;;
	logs)
		cmd_logs "$@"
		;;
	exec)
		cmd_exec "$@"
		;;
	debug)
		cmd_debug "$@"
		;;
	debug-off)
		cmd_debug_off "$@"
		;;
	test)
		cmd_test "$@"
		;;
	scaffold)
		cmd_scaffold "$@"
		;;
	prepare-release)
		cmd_prepare_release "$@"
		;;
	check-release)
		cmd_check_release "$@"
		;;
	check-compatibility)
		cmd_check_compatibility "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
