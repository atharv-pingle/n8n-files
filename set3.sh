#!/bin/bash

# ====================================================================
# N8N Deployment with Pre-populated Data Download (FIXED)
# ====================================================================

set -e

# --- 1. GLOBAL CONFIGURATION ---
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
N8N_INTERNAL_PORT="5678"

STATIC_NGROK_DOMAIN="${ENV_NGROK_DOMAIN}"
NGROK_AUTHTOKEN_DEFAULT="${ENV_NGROK_TOKEN}"
ENV_GDRIVE_URL="${ENV_GDRIVE_URL}"

N8N_DATA_HOST_PATH_DEFAULT="./n8n-data"

FILE_ID=""
FILENAME="n8n-data.zip"
VENV_NAME="gdrive_env"

# --- USAGE ---
usage() {
    echo "Usage: $0 {start|stop|logs|setup}"
    exit 1
}

# --- SETUP ENV ---
setup_env() {
    if [ -z "$STATIC_NGROK_DOMAIN" ] || [ -z "$NGROK_AUTHTOKEN_DEFAULT" ]; then
        echo "❌ ENV_NGROK_DOMAIN and ENV_NGROK_TOKEN are required"
        exit 1
    fi

    cat <<EOF > "$ENV_FILE"
N8N_DATA_HOST_PATH=${N8N_DATA_HOST_PATH_DEFAULT}
N8N_PUBLIC_URL=${STATIC_NGROK_DOMAIN}

EDITOR_BASE_URL=${STATIC_NGROK_DOMAIN}/
WEBHOOK_URL=${STATIC_NGROK_DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_RUNNERS_ENABLED=true

NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN_DEFAULT}
EOF

    echo "✅ .env created"
}

# --- DOCKER COMPOSE ---
create_docker_compose() {
    cat <<EOF > "$COMPOSE_FILE"
version: '3.7'
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: always
    mem_limit: 2048m
    mem_reservation: 1024m
    environment:
      - NODE_OPTIONS=--max_old_space_size=1500
      - EDITOR_BASE_URL=\${EDITOR_BASE_URL}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_DEFAULT_BINARY_DATA_MODE=\${N8N_DEFAULT_BINARY_DATA_MODE}
      - N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=\${N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE}
      - N8N_RUNNERS_ENABLED=\${N8N_RUNNERS_ENABLED}
    volumes:
      - \${N8N_DATA_HOST_PATH}:/home/node/.n8n
    ports:
      - "5678:5678"
EOF

    echo "✅ docker-compose.yml created"
}

# --- INSTALL DEPENDENCIES ---
install_dependencies() {
    sudo apt update
    sudo apt install -y \
        ca-certificates curl gnupg lsb-release \
        python3 python3-pip python3-venv \
        unzip git

    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "$USER"
    fi

    if ! command -v ngrok &>/dev/null; then
        curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
        | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" \
        | sudo tee /etc/apt/sources.list.d/ngrok.list
        sudo apt update
        sudo apt install -y ngrok
    fi

    sudo ngrok config add-authtoken "$NGROK_AUTHTOKEN_DEFAULT"
}

# --- DOWNLOAD DATA ---
download_n8n_data() {
    if [ -z "$ENV_GDRIVE_URL" ]; then
        echo "❌ ENV_GDRIVE_URL missing"
        exit 1
    fi

    FILE_ID=$(echo "$ENV_GDRIVE_URL" | sed -n 's#.*/d/\([^/]*\).*#\1#p')

    if [ -z "$FILE_ID" ]; then
        echo "❌ Failed to extract Google Drive file ID"
        exit 1
    fi

    if [ ! -d "$VENV_NAME" ]; then
        python3 -m venv "$VENV_NAME"
    fi

    if [ ! -f "$VENV_NAME/bin/activate" ]; then
        echo "❌ Virtualenv creation failed"
        exit 1
    fi

    source "$VENV_NAME/bin/activate"
    pip install --upgrade pip gdown
    deactivate

    mkdir -p "$N8N_DATA_HOST_PATH_DEFAULT"

    source "$VENV_NAME/bin/activate"
    gdown --id "$FILE_ID" --output "$FILENAME" --fuzzy
    deactivate

    unzip -o "$FILENAME" -d "$N8N_DATA_HOST_PATH_DEFAULT"
    rm -f "$FILENAME"
}

# --- DEPLOY ---
deploy() {
    install_dependencies
    setup_env
    create_docker_compose
    download_n8n_data

    sudo chown -R 1000:1000 "$N8N_DATA_HOST_PATH_DEFAULT"

    docker compose down || true
    docker compose pull
    docker compose up -d

    sudo pkill ngrok || true
    HOSTNAME="${STATIC_NGROK_DOMAIN#https://}"
    HOSTNAME="${HOSTNAME%/}"
    sudo ngrok http --domain="$HOSTNAME" 5678 &
}

stop_deployment() {
    sudo pkill ngrok || true
    docker compose down
}

show_logs() {
    docker compose logs -f n8n
}

case "$1" in
    start) deploy ;;
    stop) stop_deployment ;;
    logs) show_logs ;;
    setup)
        rm -f "$ENV_FILE" "$COMPOSE_FILE"
        setup_env
        create_docker_compose
        ;;
    *) usage ;;
esac
