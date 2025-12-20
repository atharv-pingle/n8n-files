#!/bin/bash

# ====================================================================
# SCRIPT: N8N Deployment + Data Restore (No Ngrok)
# ====================================================================

# --- 1. GLOBAL CONFIGURATION ---
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
N8N_INTERNAL_PORT="5678" 

# --- CONFIGURATION ---
# We read these from the environment variables passed to the script
ENV_GDRIVE_URL="${ENV_GDRIVE_URL}"
PUBLIC_DOMAIN="${ENV_DOMAIN:-http://localhost:${N8N_INTERNAL_PORT}}"

# Persistent Data Path
N8N_DATA_HOST_PATH_DEFAULT="./n8n-data"

# Configuration for GDrive Download
FILE_ID="" 
FILENAME="n8n-data.zip"
VENV_NAME="gdrive_env" 

# --- 2. FUNCTION DEFINITIONS ---

usage() {
    echo "Usage: $0 {start|stop|logs|setup}"
    echo "  start - Installs dependencies, downloads data, and starts N8N."
    echo "  stop  - Stops and removes the N8N container."
    echo "  logs  - Displays N8N logs (Press Ctrl+C to exit)."
    echo "  setup - Forces recreation of .env and docker-compose.yml files."
    exit 1
}

# --- SETUP ENVIRONMENT FILE (.env) ---
setup_env() {
    echo "--- Initial Setup: Creating $ENV_FILE ---"

    # Define Webhook URL based on user input or default to localhost
    echo "Configuring N8N to be accessible at: ${PUBLIC_DOMAIN}"

    cat <<EOF > "$ENV_FILE"
# ----------------------------------------------------------------------
# N8N CONFIGURATION
# ----------------------------------------------------------------------
N8N_DATA_HOST_PATH=${N8N_DATA_HOST_PATH_DEFAULT}

# N8n environment variables
EDITOR_BASE_URL=${PUBLIC_DOMAIN}
WEBHOOK_URL=${PUBLIC_DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_RUNNERS_ENABLED=true
EOF

    echo "✅ $ENV_FILE created successfully."
}

# --- CREATE DOCKER COMPOSE FILE ---
create_docker_compose() {
    echo "--- Creating $COMPOSE_FILE ---"
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
      - "${N8N_INTERNAL_PORT}:${N8N_INTERNAL_PORT}"
    networks:
      - default

networks:
  default:
    driver: bridge
EOF

    echo "✅ $COMPOSE_FILE created successfully."
}

# --- INSTALL DOCKER AND UTILS ---
install_dependencies() {
    echo ""
    echo "--- Installing System Dependencies (Docker, Python/Venv, Unzip) ---"
    sudo apt update > /dev/null 2>&1
    echo "✅ System packages updated."

    echo "Installing essential packages..."
    sudo apt install -y ca-certificates curl gnupg lsb-release python3-pip python3-venv unzip git

    # Install Docker
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update > /dev/null 2>&1
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        if ! getent group docker > /dev/null; then sudo groupadd docker; fi
        sudo usermod -aG docker "$USER"
        echo "✅ Docker installed."
    else
        echo "✅ Docker found. Skipping installation."
    fi
}

# --- DOWNLOAD AND PREPARE N8N DATA ---
download_n8n_data() {
    echo ""
    echo "--- 🔄 Starting N8N Persistent Data Preparation ---"
    
    # Check for variable
    if [ -z "$ENV_GDRIVE_URL" ]; then
      echo "❌ Error: ENV_GDRIVE_URL is not set." >&2
      exit 1
    fi
    
    # Extract File ID
    FILE_ID=$(echo "$ENV_GDRIVE_URL" | awk -F'[/=]' '{
        for (i=1; i<=NF; i++) {
            if ($i == "d" && $(i+1) != "") { print $(i+1); exit }
            if ($i == "id") { print $(i+1); exit }
        }
    }')

    if [ -z "$FILE_ID" ]; then
        echo "❌ Error: Could not reliably extract File ID from ENV_GDRIVE_URL."
        exit 1
    fi
    echo "✅ Extracted File ID: $FILE_ID"

    # 1. Create and activate virtual environment for gdown
    if [ ! -d "$VENV_NAME" ]; then
        echo "Creating virtual environment: $VENV_NAME"
        if ! dpkg -s python3-venv >/dev/null 2>&1; then
            sudo apt install -y python3-venv
        fi
        python3 -m venv "$VENV_NAME"
    fi

    # 2. Install gdown
    echo "Installing gdown into $VENV_NAME..."
    if [ -f "$VENV_NAME/bin/activate" ]; then
        source "$VENV_NAME/bin/activate" && pip install gdown > /dev/null 2>&1
    else
        echo "❌ Error: Virtual environment activation script not found."
        exit 1
    fi
    
    if [ ! -f "$VENV_NAME/bin/gdown" ]; then
        echo "❌ gdown installation failed. Exiting."
        exit 1
    fi

    # 3. Create host data directory
    if [ ! -d "$N8N_DATA_HOST_PATH_DEFAULT" ]; then
        mkdir -p "$N8N_DATA_HOST_PATH_DEFAULT"
        echo "✅ Created persistent data directory: $N8N_DATA_HOST_PATH_DEFAULT"
    fi

    # 4. Execute gdown command
    echo "--- 📥 Downloading Google Drive File (ID: ${FILE_ID}) ---"
    gdown --id "${FILE_ID}" --output "${FILENAME}" --no-cookies --fuzzy
    DOWNLOAD_STATUS=$?
    deactivate 

    if [ $DOWNLOAD_STATUS -ne 0 ] || [ ! -s "${FILENAME}" ]; then
        echo "❌ Download failed or file is empty. Exiting deployment."
        exit 1
    fi

    echo "✅ Download complete."

    # 5. Unzip the file
    echo "--- 📂 Unzipping ${FILENAME} ---"
    unzip -o "${FILENAME}" -d "$N8N_DATA_HOST_PATH_DEFAULT"

    if [ $? -eq 0 ]; then
        # Check for nested directory issue
        NESTED_PATH="${N8N_DATA_HOST_PATH_DEFAULT}/$(basename "$N8N_DATA_HOST_PATH_DEFAULT")"
        if [ -d "$NESTED_PATH" ] && [ -n "$(ls -A "$NESTED_PATH")" ]; then
            echo "--- ⚠️ Nested directory detected! Fixing data path... ---"
            find "$NESTED_PATH" -mindepth 1 -maxdepth 1 -exec mv -t "$N8N_DATA_HOST_PATH_DEFAULT" {} +
            rmdir "$NESTED_PATH"
            echo "✅ Data moved to root path."
        fi
    fi

    # 6. Cleanup
    rm -f "${FILENAME}"
    echo "✅ Cleanup complete."
}

# --- DEPLOYMENT FUNCTIONS ---

deploy() {
    # Check Secrets
    if [ -z "$ENV_GDRIVE_URL" ]; then
        echo "❌ Error: 'start' command requires ENV_GDRIVE_URL." >&2
        echo "Please 'export ENV_GDRIVE_URL=...' before running." >&2
        exit 1
    fi
    
    # 1. Install Dependencies
    install_dependencies

    # 2. Setup config files
    setup_env
    create_docker_compose

    # 3. Download Data
    download_n8n_data

    # 4. Permissions
    echo "--- Setting Permissions ---"
    sudo chown -R 1000:1000 "$N8N_DATA_HOST_PATH_DEFAULT"

    # 5. Start Docker
    echo "--- Starting N8N Deployment ---"
    docker compose -f "$COMPOSE_FILE" down --remove-orphans > /dev/null 2>&1
    docker compose -f "$COMPOSE_FILE" pull 
    docker compose -f "$COMPOSE_FILE" up -d --build

    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================================="
        echo "🚀 N8N DEPLOYMENT COMPLETED!"
        echo "N8N is running on Port ${N8N_INTERNAL_PORT}"
        echo ""
        echo "Access URL: ${PUBLIC_DOMAIN}"
        echo "=========================================================="
    else
        echo "Deployment failed. Check Docker status."
    fi
}

stop_deployment() {
    echo "--- Stopping Deployment ---"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        echo "✅ N8N container stopped and removed."
    else
        echo "No docker-compose.yml file found."
    fi
}

show_logs() {
    echo "--- Showing N8N Logs ---"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f n8n
    else
        echo "Error: docker-compose.yml not found."
    fi
}

# --- 3. MAIN EXECUTION ---
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
