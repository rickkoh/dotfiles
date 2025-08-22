#!/usr/bin/env bash
set -euo pipefail

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}App Deploy Scaffolder${RESET}"
echo -e "${DIM}
This will generate a ready-to-use production deployment scaffold:
- server-setup.sh (installs Docker, Nginx, Certbot; HTTP→HTTPS; cron renew)
- docker-compose.prod.yml (App + Nginx reverse proxy with TLS via Let's Encrypt)
- nginx.conf (placeholder; server-setup overwrites with HTTP/TLS configs)
- deploy.sh / update.sh
- .github/workflows/deploy.yml (CI: build & push to GHCR, then SSH deploy)

What you still do manually later:
1) Point your DOMAIN A-record to your server's IP
2) Create your app's Dockerfile(.prod) and push code to GitHub
3) Create GitHub Actions secrets (if you enabled CI)
4) SSH into the server and run server-setup.sh (first-time bootstrap)

Press Enter to accept defaults in [brackets].
${RESET}"

# --- helpers ---
ask() {
  local prompt="$1"
  local default="${2:-}"
  local var
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " var || true
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}" # Y or N
  local ans
  read -r -p "$prompt (y/N): " ans || true
  ans="${ans:-$default}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then return 0; else return 1; fi
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# --- gather inputs ---
APP_NAME="$(ask "App name (used for folder & service names)" "myapp")"
APP_SLUG="$(slugify "$APP_NAME")"
DOMAIN="$(ask "Primary domain (FQDN)" "example.com")"
INTERNAL_PORT="$(ask "Internal app port (container port)" "1234")"
LE_EMAIL="$(ask "Email for Let's Encrypt" "admin@${DOMAIN}")"

# GitHub/GHCR settings
GH_USER="$(ask "GitHub username/org" "your-github-user")"
GHCR_REPO="$(ask "GHCR repository (e.g. ${APP_SLUG})" "${APP_SLUG}")"
GHCR_TAG="$(ask "GHCR tag" "latest")"

# Server settings
HOST="$(ask "Server IP address" "your.server.ip")"
HOST_USER="$(ask "Server username (with sudo)" "ubuntu")"

# Choose how the app service gets its image
echo ""
echo -e "${BOLD}How should production image be provided?${RESET}"
echo "1) Build locally from Dockerfile.prod (default)"
echo "2) Pull from GHCR (ghcr.io/<user>/<repo>:<tag>)"
IMG_MODE="$(ask "Choose 1 or 2" "1")"

GHCR_IMAGE=""
if [[ "$IMG_MODE" == "2" ]]; then
  GHCR_IMAGE="ghcr.io/${GH_USER}/${GHCR_REPO}:${GHCR_TAG}"
fi

INCLUDE_CI=true
if ! ask_yes_no "Include GitHub Actions workflow for CI/CD?" "Y"; then
  INCLUDE_CI=false
fi

INCLUDE_BACKUP=false
if ask_yes_no "Include simple local backup scripts (disabled by default)?"; then
  INCLUDE_BACKUP=true
fi

PROJECT_NAME="${APP_SLUG}-deploy"
mkdir -p "${PROJECT_NAME}"
mkdir -p "${PROJECT_NAME}/.github/workflows"

echo ""
echo -e "${GREEN}Generating files in ${PROJECT_NAME}/ ...${RESET}"

# --- nginx.conf placeholder (server-setup will overwrite) ---
cat > "${PROJECT_NAME}/nginx.conf" <<'NGINXPH'
# Placeholder. server-setup.sh will write HTTP-only config first,
# then switch to TLS after Certbot succeeds.
# Keeping this file here so docker-compose can mount it on first boot.
server {
  listen 80 default_server;
  server_name _;
  return 444;
}
NGINXPH

# --- docker-compose.prod.yml ---
if [[ "$IMG_MODE" == "2" ]]; then
  APP_SERVICE_BLOCK=$(cat <<EOF
  app:
    image: ${GHCR_IMAGE}
    container_name: ${APP_SLUG}-app
    restart: unless-stopped
    expose:
      - "${INTERNAL_PORT}"
    environment:
      NODE_ENV: production
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${INTERNAL_PORT}"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
)
else
  APP_SERVICE_BLOCK=$(cat <<EOF
  app:
    build:
      context: .
      dockerfile: Dockerfile.prod
    image: ${APP_SLUG}:latest
    container_name: ${APP_SLUG}-app
    restart: unless-stopped
    expose:
      - "${INTERNAL_PORT}"
    environment:
      NODE_ENV: production
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:${INTERNAL_PORT}"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
)
fi

cat > "${PROJECT_NAME}/docker-compose.prod.yml" <<EOF
version: "3.8"

services:
${APP_SERVICE_BLOCK}

  nginx:
    image: nginx:alpine
    container_name: ${APP_SLUG}-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - certbot-www:/var/www/certbot
      - letsencrypt:/etc/letsencrypt
    depends_on:
      - app

volumes:
  certbot-www:
    name: ${APP_SLUG}-certbot-www
  letsencrypt:
    name: ${APP_SLUG}-letsencrypt
EOF

# --- server-setup.sh ---
cat > "${PROJECT_NAME}/server-setup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_SLUG="${APP_SLUG}"
APP_NAME="${APP_NAME}"
DOMAIN="${DOMAIN}"
LE_EMAIL="${LE_EMAIL}"
INTERNAL_PORT="${INTERNAL_PORT}"
GH_USER="${GH_USER}"

echo "🚀 Setting up production server for \${APP_SLUG}..."

if [ "\${EUID}" -eq 0 ]; then
  echo "❌ Please run as a regular user with sudo privileges, not root."
  exit 1
fi

echo "📦 Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "🐳 Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  sudo usermod -aG docker "\$USER"
  rm get-docker.sh
else
  echo "✅ Docker already installed"
fi

echo "📦 Installing Docker Compose..."
if ! command -v docker-compose >/dev/null 2>&1; then
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
else
  echo "✅ Docker Compose already installed"
fi

echo "📝 Installing dnsutils..."
if ! command -v dig >/dev/null 2>&1; then
  sudo apt install -y dnsutils
fi

echo "🔥 Configuring firewall..."
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 22/tcp || true
  sudo ufw allow 80/tcp || true
  sudo ufw allow 443/tcp || true
  sudo ufw delete allow ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true
  sudo ufw --force enable
fi

echo "📁 Creating app directory..."
mkdir -p ~/apps/\${APP_NAME}
cd ~/apps/\${APP_NAME}

echo "📁 Ensuring nginx.conf exists (HTTP placeholder)..."
if [ -d nginx.conf ]; then
  rm -rf nginx.conf
fi

cat > nginx.conf <<NGINXHTTP
server {
  listen 80;
  server_name \${DOMAIN};

  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }

  location / {
    proxy_pass http://app:\${INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    client_max_body_size 50M;
    proxy_read_timeout 300;
  }
}
NGINXHTTP

echo "🐳 Bringing up app + Nginx (HTTP only) with docker-compose.prod.yml..."
docker-compose -f docker-compose.prod.yml up -d

echo "🔎 Checking DNS A record for \${DOMAIN}..."
if ! dig +short "\${DOMAIN}" A | grep -q "."; then
  echo "⚠️  DNS A record not found. Point \${DOMAIN} to this server's IP, then re-run this script."
  exit 0
fi

echo "🔏 Requesting certificate via Certbot (webroot)..."
docker run --rm \
  -v \${APP_SLUG}-letsencrypt:/etc/letsencrypt \
  -v \${APP_SLUG}-certbot-www:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d "\${DOMAIN}" \
  --email "\${LE_EMAIL}" --agree-tos --no-eff-email || true

echo "🔍 Verifying certificate presence..."
if docker run --rm -v \${APP_SLUG}-letsencrypt:/etc/letsencrypt alpine sh -c "[ -f /etc/letsencrypt/live/\${DOMAIN}/fullchain.pem ]"; then
  echo "✅ Certificate obtained. Switching Nginx to TLS..."
  cat > nginx.conf <<NGINXTLS
server {
  listen 80;
  server_name \${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name \${DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/\${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/\${DOMAIN}/privkey.pem;
  ssl_trusted_certificate /etc/letsencrypt/live/\${DOMAIN}/chain.pem;

  # Recommended SSL settings
  ssl_session_timeout 1d;
  ssl_session_cache shared:MozSSL:10m;
  ssl_session_tickets off;

  # Modern ciphers (compatible with most clients)
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    proxy_pass http://app:\${INTERNAL_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    client_max_body_size 50M;
    proxy_read_timeout 300;
  }
}
NGINXTLS

  docker-compose -f docker-compose.prod.yml restart nginx || true

  echo "⏲️  Installing daily cert auto-renew cron..."
  (crontab -l 2>/dev/null; echo "0 3 * * * docker run --rm -v \${APP_SLUG}-letsencrypt:/etc/letsencrypt -v \${APP_SLUG}-certbot-www:/var/www/certbot certbot/certbot:latest renew --webroot -w /var/www/certbot && docker exec \${APP_SLUG}-nginx nginx -s reload") | crontab -
else
  echo "❌ Certificate not found. Keeping HTTP. Fix DNS or re-run later."
fi

echo ""
echo "✅ Server bootstrap completed."
echo "Next steps:"
echo "  - Ensure your app's Docker image is available (build locally or via CI)"
echo "  - docker-compose -f docker-compose.prod.yml ps"
echo "  - Access: http://\${DOMAIN} (and https:// once cert is in place)"
EOF
chmod +x "${PROJECT_NAME}/server-setup.sh"

# --- deploy.sh (combining both approaches) ---
cat > "${PROJECT_NAME}/deploy.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker-compose -f docker-compose.prod.yml"
GH_USER="${GH_USER}"
APP_NAME="${APP_NAME}"
HOST="${HOST}"
HOST_USER="${HOST_USER}"

echo "🚀 Deploying (production)..."

if [ -f Dockerfile.prod ]; then
  echo "📦 Building and pushing Docker image..."
  docker build -t ghcr.io/\${GH_USER}/\${APP_NAME}:latest -f Dockerfile.prod .
  docker push ghcr.io/\${GH_USER}/\${APP_NAME}:latest

  echo "🚀 SSH into server and pulling latest image..."
  ssh -i ~/.ssh/id_rsa \${HOST_USER}@\${HOST} << EOSSH
    cd ~/apps/\${APP_NAME}
    docker pull ghcr.io/\${GH_USER}/\${APP_NAME}:latest || true
    docker-compose -f docker-compose.prod.yml down
    docker-compose -f docker-compose.prod.yml up -d
    docker-compose -f docker-compose.prod.yml ps
EOSSH
else
  echo "📦 Building local image (Dockerfile.prod not found, using Dockerfile)..."
  \$COMPOSE build --no-cache app || true
  
  echo "🚀 Starting containers..."
  \$COMPOSE up -d
  
  echo "📊 Status:"
  \$COMPOSE ps
fi

echo "✅ Deploy complete!"
echo "ℹ️  Logs: \$COMPOSE logs -f"
EOF
chmod +x "${PROJECT_NAME}/deploy.sh"

# --- update.sh (simple rolling update flow) ---
cat > "${PROJECT_NAME}/update.sh" <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker-compose -f docker-compose.prod.yml"

echo "🔄 Updating deployment..."

# Optional pre-update backup hook (disabled by default)
if [ -x ./backup.sh ]; then
  echo "💾 Running backup..."
  ./backup.sh || echo "⚠️  Backup failed or not configured; continuing."
fi

if [ -f Dockerfile.prod ]; then
  echo "📦 Rebuilding image..."
  $COMPOSE build --no-cache app
else
  echo "⬇️  Pulling latest image..."
  $COMPOSE pull app || true
fi

echo "🚀 Restarting..."
$COMPOSE up -d

echo "📊 Status:"
$COMPOSE ps
UPDATE
chmod +x "${PROJECT_NAME}/update.sh"

# --- optional: backup.sh (simple stub) ---
if [[ "$INCLUDE_BACKUP" == true ]]; then
  cat > "${PROJECT_NAME}/backup.sh" <<'BACKUP'
#!/usr/bin/env bash
set -euo pipefail

# Simple local backup stub.
# Customize for your app/data store. For SQLite or file uploads,
# consider mounting named volumes and tar them similar to below.

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="./backups/${STAMP}"
mkdir -p "${OUTDIR}"

echo "💾 Starting backup to ${OUTDIR}"
# Example: back up a named volume (change 'my-volume' to your volume name)
# docker run --rm -v my-volume:/data -v "$(pwd)/${OUTDIR}":/backup alpine sh -c "tar czf /backup/data.tar.gz -C /data ."

echo "✅ Backup stub complete (no-op). Customize backup.sh for your stack."
BACKUP
  chmod +x "${PROJECT_NAME}/backup.sh"
fi

# --- GitHub Actions workflow (combining both approaches) ---
if [[ "$INCLUDE_CI" == true ]]; then
  cat > "${PROJECT_NAME}/.github/workflows/deploy.yml" <<EOF
name: Build & Deploy ${APP_NAME}

on:
  push:
    branches: [ "main" ]

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ secrets.GHCR_USERNAME }}
          password: \${{ secrets.GHCR_TOKEN }}

      - name: Build and push image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.prod
          push: true
          tags: ghcr.io/\${{ secrets.GHCR_USERNAME }}/${GHCR_REPO}:latest

  deploy:
    needs: build-push
    runs-on: ubuntu-latest
    steps:
      - name: SSH and deploy
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: \${{ secrets.HOST }}
          username: \${{ secrets.HOST_USER }}
          key: \${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            set -e
            cd ~/apps/${APP_NAME} || exit 1
            docker pull ghcr.io/\${{ secrets.GHCR_USERNAME }}/${GHCR_REPO}:latest || true
            docker-compose -f docker-compose.prod.yml down
            docker-compose -f docker-compose.prod.yml up -d
            docker-compose -f docker-compose.prod.yml ps
EOF
fi

# --- README-GENERATED.md (combining information from both) ---
cat > "${PROJECT_NAME}/README-GENERATED.md" <<EOF
# ${APP_NAME} – Production Deploy Scaffold

Generated by init-server.sh

## What you got

- \`server-setup.sh\`: installs Docker, Nginx, Certbot; HTTP→HTTPS; cron renew
- \`docker-compose.prod.yml\`: app + nginx reverse proxy (80/443), cert volumes
- \`nginx.conf\`: placeholder; rewritten by \`server-setup.sh\`
- \`deploy.sh\`: build/push to GHCR locally or compose up
- \`update.sh\`: backup → pull/build → restart
$( [[ "$INCLUDE_BACKUP" == true ]] && echo "- \`backup.sh\` (stub – customize for your data)" )
$( [[ "$INCLUDE_CI" == true ]] && echo "- \`.github/workflows/deploy.yml\` (GHCR + SSH deploy)" )

## Before First Deployment

1. **Point DNS A record** of **${DOMAIN}** to your server IP (**${HOST}**).

2. **Copy this folder to your server** (recommended location: \`/opt/${APP_SLUG}\` or \`~/apps/${APP_NAME}\`):
   \`\`\`bash
   scp -r ${PROJECT_NAME}/ ${HOST_USER}@${HOST}:~/apps/${APP_NAME}/
   \`\`\`

3. **SSH into the server and run the setup**:
   \`\`\`bash
   ssh ${HOST_USER}@${HOST}
   cd ~/apps/${APP_NAME}
   chmod +x server-setup.sh
   ./server-setup.sh
   \`\`\`

4. **Add an \`.env\` file** alongside \`docker-compose.prod.yml\` if your app needs it.

5. **If you enabled CI**, add GitHub repository secrets:
   - \`GHCR_USERNAME\` = ${GH_USER}
   - \`GHCR_TOKEN\` = your GitHub Personal Access Token with \`write:packages\`
   - \`HOST\` = ${HOST}
   - \`HOST_USER\` = ${HOST_USER}
   - \`SSH_PRIVATE_KEY\` = your private key used for SSH

## Deployment Options

### Option 1: GitHub Actions (Automatic)
- Push to main branch → GitHub Actions will auto-deploy
- Builds Docker image and pushes to GHCR
- SSH deploys to your server

### Option 2: Manual Local Deploy
\`\`\`bash
./deploy.sh
\`\`\`

### Option 3: Server-side Update
SSH into server and run:
\`\`\`bash
cd ~/apps/${APP_NAME}
./update.sh
\`\`\`

## Access Your App

- HTTP:  \`http://${DOMAIN}\`
- HTTPS: \`https://${DOMAIN}\` (once cert is issued)

## Notes

- Ensure your \`Dockerfile.prod\` exists in your project root
- Server setup includes automatic SSL certificate renewal via cron
- Backups are not included by default (customize \`backup.sh\` if enabled)
- Logs: \`docker-compose -f docker-compose.prod.yml logs -f\`
EOF

echo ""
echo -e "${GREEN}✅ All setup files generated in: ${BOLD}${PROJECT_NAME}/${RESET}"
echo ""
echo "Generated files:"
echo "   - server-setup.sh"
echo "   - docker-compose.prod.yml"
echo "   - nginx.conf"
echo "   - deploy.sh"
echo "   - update.sh"
$( [[ "$INCLUDE_BACKUP" == true ]] && echo "   - backup.sh" )
$( [[ "$INCLUDE_CI" == true ]] && echo "   - .github/workflows/deploy.yml" )
echo "   - README-GENERATED.md"
echo ""
echo -e "Next steps:
  1. ${YELLOW}cd ${PROJECT_NAME}${RESET}
  2. ${YELLOW}git init && git add . && git commit -m \"chore: scaffold deploy\"${RESET}
  3. ${YELLOW}Review README-GENERATED.md for deployment instructions${RESET}
  4. ${YELLOW}Copy folder to server: scp -r ${PROJECT_NAME}/ ${HOST_USER}@${HOST}:~/apps/${APP_NAME}/${RESET}
  5. ${YELLOW}SSH into server and run: ./server-setup.sh${RESET}
"
