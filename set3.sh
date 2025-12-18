#!/bin/bash

# ====================================================================
# MERGED SCRIPT: N8N Deployment with Pre-populated Data Download
# ====================================================================

# --- 1. GLOBAL CONFIGURATION ---
# Configuration for Docker/Deployment
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"
N8N_INTERNAL_PORT="5678" # N8N container runs on 5678 internally

# --- 🔒 SECURE CONFIGURATION ---
# Variables will be read from the environment.
# Checks are now INSIDE the functions that need them.
STATIC_NGROK_DOMAIN="${ENV_NGROK_DOMAIN}"
NGROK_AUTHTOKEN_DEFAULT="${ENV_NGROK_TOKEN}"
ENV_GDRIVE_URL="${ENV_GDRIVE_URL}" # Added this to global scope

# Persistent Data Path
N8N_DATA_HOST_PATH_DEFAULT="./n8n-data"

# Configuration for GDrive Download
FILE_ID="" # Will be set by download_n8n_data()
FILENAME="n8n-data.zip"
VENV_NAME="gdrive_env" # Virtual environment for gdown

# --- 2. FUNCTION DEFINITIONS ---

# Function to display usage information
usage() {
    echo "Usage: $0 {start|stop|logs|setup}"
    echo "  start - Installs dependencies, downloads data, sets up files, and starts N8N/Ngrok."
    echo "  stop  - Stops and removes the N8N container and the background Ngrok process."
    echo "  logs  - Displays N8N logs (Press Ctrl+C to exit)."
    echo "  setup - Forces recreation of .env and docker-compose.yml files."
    exit 1
}

# --- SETUP ENVIRONMENT FILE (.env) ---
setup_env() {
    # Check for variables
    if [ -z "$STATIC_NGROK_DOMAIN" ] || [ -z "$NGROK_AUTHTOKEN_DEFAULT" ]; then
       echo "❌ Error: 'setup' command requires ENV_NGROK_DOMAIN and ENV_NGROK_TOKEN." >&2
       exit 1
    fi
    
    echo "--- Initial Setup: Creating $ENV_FILE ---"

    cat <<EOF > "$ENV_FILE"
# ----------------------------------------------------------------------
# N8N CONFIGURATION (Using static Ngrok domain)
# ----------------------------------------------------------------------
N8N_DATA_HOST_PATH=${N8N_DATA_HOST_PATH_DEFAULT}
N8N_PUBLIC_URL=${STATIC_NGROK_DOMAIN}

# N8n environment variables using the static public URL
EDITOR_BASE_URL=${STATIC_NGROK_DOMAIN}/
WEBHOOK_URL=${STATIC_NGROK_DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_RUNNERS_ENABLED=true

# ----------------------------------------------------------------------
# NGROK CONFIGURATION (Host install)
# ----------------------------------------------------------------------
NGROK_AUTHTOKEN=${NGROK_AUTHTOKEN_DEFAULT}
EOF

    echo "✅ $ENV_FILE created successfully."
    echo "⚠️ NOTE: N8N is configured for the static domain: ${STATIC_NGROK_DOMAIN}"
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

    echo "✅ $COMPOSE_FILE created successfully (with memory limits added)."
}

# --- INSTALL DOCKER, NGROK, AND PYTHON BASE DEPENDENCIES ---
install_dependencies() {
    # Check for variables
    if [ -z "$NGROK_AUTHTOKEN_DEFAULT" ]; then
      echo "❌ Error: ENV_NGROK_TOKEN is not set. Cannot configure Ngrok." >&2
      exit 1
    fi

    echo ""
    echo "--- Installing System Dependencies (Docker, Ngrok, Python/Venv, Unzip, Git) ---"
    sudo apt update > /dev/null 2>&1
    echo "✅ System packages updated."

    echo "Installing essential packages..."
    # REMOVED python3-full to prevent apt errors on some Ubuntu versions
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

    # Install Ngrok
    if ! command -v ngrok &> /dev/null; then
        echo "Installing Ngrok..."
        curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
          | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null \
          && echo "deb https://ngrok-agent.s3.amazonaws.com bookworm main" \
          | sudo tee /etc/apt/sources.list.d/ngrok.list \
          && sudo apt update > /dev/null 2>&1 \
          && sudo apt install -y ngrok
        echo "✅ Ngrok installed."
    else
        echo "✅ Ngrok found. Skipping installation."
    fi

    # Configure Ngrok Authtoken on Host
    echo "--- Configuring Ngrok Authtoken ---"
    sudo ngrok config add-authtoken "${NGROK_AUTHTOKEN_DEFAULT}"
    echo "✅ Ngrok authtoken configured on host."
}

# --- DOWNLOAD AND PREPARE N8N DATA (Script 1 Logic) ---
download_n8n_data() {
    echo ""
    echo "--- 🔄 Starting N8N Persistent Data Preparation ---"
    
    # Check for variable
    if [ -z "$ENV_GDRIVE_URL" ]; then
      echo "❌ Error: ENV_GDRIVE_URL is not set." >&2
      exit 1
    fi
    
    # Extract File ID from the environment variable
    FILE_ID=$(echo "$ENV_GDRIVE_URL" | awk -F'[/=]' '{
        for (i=1; i<=NF; i++) {
            if ($i == "d" && $(i+1) != "") { print $(i+1); exit }
            if ($i == "id") { print $(i+1); exit }
        }
    }')

    if [ -z "$FILE_ID" ]; then
        echo "❌ Error: Could not reliably extract File ID from the provided ENV_GDRIVE_URL."
        echo "Please ensure the URL is valid. URL was: '$ENV_GDRIVE_URL'"
        exit 1
    fi
    echo "✅ Extracted File ID: $FILE_ID"

    # 1. Create and activate virtual environment for gdown
    if [ ! -d "$VENV_NAME" ]; then
        echo "Creating virtual environment: $VENV_NAME"
        
        # Double check python3-venv is installed before trying
        if ! dpkg -s python3-venv >/dev/null 2>&1; then
            echo "⚠️  python3-venv missing. Installing..."
            sudo apt install -y python3-venv
        fi
        
        python3 -m venv "$VENV_NAME"
        if [ $? -ne 0 ]; then
            echo "❌ Error: Failed to create virtual environment. 'python3-venv' might still be missing."
            exit 1
        fi
    fi

    # 2. Install gdown inside the virtual environment
    echo "Installing gdown into $VENV_NAME..."
    # Ensure source works by checking file existence first
    if [ -f "$VENV_NAME/bin/activate" ]; then
        source "$VENV_NAME/bin/activate" && pip install gdown > /dev/null 2>&1
    else
        echo "❌ Error: Virtual environment activation script not found."
        exit 1
    fi
    
    if [ ! -f "$VENV_NAME/bin/gdown" ]; then
        echo "❌ gdown installation failed. Cannot proceed with download. Exiting deployment."
        exit 1
    fi
    echo "✅ gdown is installed and ready."

    # 3. Create host data directory
    if [ ! -d "$N8N_DATA_HOST_PATH_DEFAULT" ]; then
        mkdir -p "$N8N_DATA_HOST_PATH_DEFAULT"
        echo "✅ Created persistent data directory: $N8N_DATA_HOST_PATH_DEFAULT"
    fi

    # 4. Execute gdown command
    echo "--- 📥 Downloading Google Drive File (ID: ${FILE_ID}) using gdown ---"
    gdown --id "${FILE_ID}" --output "${FILENAME}" --no-cookies --fuzzy
    DOWNLOAD_STATUS=$?
    deactivate 

    if [ $DOWNLOAD_STATUS -ne 0 ] || [ ! -s "${FILENAME}" ]; then
        echo "❌ Download failed or file is empty. Exiting deployment."
        exit 1
    fi

    echo "✅ Download complete (File size: $(du -h "${FILENAME}" | awk '{print $1}'))."
    echo ""

    # 5. Unzip the file
    echo "--- 📂 Unzipping ${FILENAME} to ${N8N_DATA_HOST_PATH_DEFAULT} ---"
    unzip -o "${FILENAME}" -d "$N8N_DATA_HOST_PATH_DEFAULT"

    if [ $? -ne 0 ]; then
        echo "❌ WARNING: Unzip failed. The downloaded file might be corrupted. Continuing cleanup."
    else
        echo "✅ File extraction attempted."
        # FIX: Check for and fix common nested directory issue
        NESTED_PATH="${N8N_DATA_HOST_PATH_DEFAULT}/$(basename "$N8N_DATA_HOST_PATH_DEFAULT")"
        if [ -d "$NESTED_PATH" ] && [ -n "$(ls -A "$NESTED_PATH")" ]; then
            echo "--- ⚠️ Nested directory detected! Fixing data path... ---"
            find "$NESTED_PATH" -mindepth 1 -maxdepth 1 -exec mv -t "$N8N_DATA_HOST_PATH_DEFAULT" {} +
            rmdir "$NESTED_PATH"
            echo "✅ Data moved to the correct root path: ${N8N_DATA_HOST_PATH_DEFAULT}"
        fi
    fi

    # 6. Cleanup
    echo "--- 🧹 Cleaning up zip archive ---"
    rm -f "${FILENAME}"
    echo "✅ Removed ${FILENAME}. Environment '$VENV_NAME' remains for future use."
    echo ""
}

# --- DEPLOYMENT AND MANAGEMENT FUNCTIONS ---

deploy() {
    # --- 🔒 Verifying Secrets for 'start' command ---
    if [ -z "$STATIC_NGROK_DOMAIN" ] || [ -z "$NGROK_AUTHTOKEN_DEFAULT" ] || [ -z "$ENV_GDRIVE_URL" ]; then
        echo "❌ Error: 'start' command requires ENV_NGROK_DOMAIN, ENV_NGROK_TOKEN, and ENV_GDRIVE_URL." >&2
        echo "Please 'export' them before running 'sudo -E bash set3.sh start'" >&2
        exit 1
    fi
    echo "✅ Secrets verified."
    
    # 1. Install Dependencies
    install_dependencies

    # 2. Setup config files
    setup_env
    create_docker_compose

    # 3. Download and populate N8N data
    download_n8n_data

    # 4. Ensure correct ownership
    echo "--- Setting Permissions on Data Directory ---"
    if sudo chown -R 1000:1000 "$N8N_DATA_HOST_PATH_DEFAULT"; then
        echo "✅ Set correct ownership (1000:1000) for n8n persistence."
    else
        echo "❌ WARNING: Failed to set ownership (chown) on $N8N_DATA_HOST_PATH_DEFAULT."
    fi

    # 5. Start Deployment
    echo "--- Starting N8N Deployment ---"
    docker compose -f "$COMPOSE_FILE" down --remove-orphans > /dev/null 2>&1
    docker compose -f "$COMPOSE_FILE" pull 
    docker compose -f "$COMPOSE_FILE" up -d --build

    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================================="
        echo "🚀 STEP 1/2: N8N DOCKER DEPLOYMENT COMPLETED!"
        echo "N8N is running on your server's host port 5678."
        
        # --- Start Ngrok Tunnel ---
        echo ""
        echo "--- Starting Ngrok Tunnel Automatically (Detached) ---"
        
        echo "Attempting to terminate any existing ngrok process..."
        sudo pkill ngrok || true
        sleep 1 

        # --- ‼️ PERMANENT FIX ‼️ ---
        # Strip https:// from the front AND any trailing / from the domain
        HOSTNAME_TEMP="${STATIC_NGROK_DOMAIN#https://}"
        NGROK_HOSTNAME="${HOSTNAME_TEMP%/}" # This removes the trailing /
        # --- END FIX ---
        
        NGROK_CMD="sudo ngrok http --domain=${NGROK_HOSTNAME} ${N8N_INTERNAL_PORT}"
        echo "Executing: $NGROK_CMD &"
        $NGROK_CMD &
        
        echo "✅ Ngrok tunnel started in the background."
        echo ""
        echo "=========================================================="
        echo "🚀 STEP 2/2: NGROK TUNNEL STARTED!"
        echo "Access your N8N instance at:"
        echo "----------------------------------------------------------"
        echo "${STATIC_NGROK_DOMAIN}"
        echo "----------------------------------------------------------"
        echo "=========================================================="
    else
        echo "Deployment failed. Check Docker status."
    fi
}

stop_deployment() {
    echo "--- Stopping Deployment ---"
    echo "Stopping background ngrok process..."
    sudo pkill ngrok || true
    
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" down --remove-orphans
        echo "N8N container stopped and removed."
    else
        echo "No docker-compose.yml file found. Skipping Docker stop."
    fi
}

show_logs() {
    echo "--- Showing N8N Container Logs (Press Ctrl+C to exit) ---"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f n8n
    else
        echo "Error: docker-compose.yml not found. Run 'start' first."
    fi
}

# --- 3. MAIN EXECUTION ---
case "$1" in
    start)
        deploy
        ;;

    stop)
        stop_deployment
        ;;

    logs)
        show_logs
        ;;

    setup)
        # This command also needs the variables, so we call setup_env
        # which has the checks inside it.
        rm -f "$ENV_FILE" "$COMPOSE_FILE"
        setup_env
        create_docker_compose
        ;;

    *)
        usage
        ;;
esac
