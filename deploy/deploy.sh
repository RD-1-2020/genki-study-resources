#!/bin/bash

# Deployment script for Genki Study Resources
# Usage: ./deploy.sh

SSH_KEY=""
SSH_PASSPHRASE=''
REMOTE_HOST=
REMOTE_USER=root
REMOTE_DIR="/opt/genki"

# 0. Check if SSH Key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "Error: SSH Private Key not found at $SSH_KEY"
    exit 1
fi

# Fix permissions for the private key (SSH requires 600)
chmod 600 "$SSH_KEY"

# 1. Setup authentication options using sshpass for the key passphrase
if [ -n "$SSH_PASSPHRASE" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "Error: 'sshpass' is required to automate the private key passphrase."
        echo "Please install it: sudo apt install sshpass (WSL/Linux) or brew install sshpass (Mac)"
        exit 1
    fi
    
    # Export passphrase to environment for security
    export SSHPASS="$SSH_PASSPHRASE"
    
    # -e: use SSHPASS env var
    # -P passphrase: look for the key passphrase prompt specifically
    AUTH_ARGS="sshpass -e -P passphrase"
    SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
    
    SSH_CMD="$AUTH_ARGS ssh $SSH_OPTS"
    SCP_CMD="$AUTH_ARGS scp $SSH_OPTS"
    RSYNC_SSH_CMD="$AUTH_ARGS ssh $SSH_OPTS"
    
    echo "Using SSH Key ($SSH_KEY) with automated passphrase..."
else
    SSH_CMD="ssh -i $SSH_KEY"
    SCP_CMD="scp -i $SSH_KEY"
    RSYNC_SSH_CMD="ssh -i $SSH_KEY"
    echo "Using SSH Key ($SSH_KEY) without passphrase..."
fi

echo "---------------------------------------------------"
echo "Deploying to $REMOTE_USER@$REMOTE_HOST"
echo "Target directory: $REMOTE_DIR"
echo "---------------------------------------------------"

# 2. Create remote directory if it doesn't exist
echo "Creating remote directory..."
$SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

# Ensure rsync is installed on remote (needed for efficient transfers)
echo "Checking for rsync on remote..."
if ! $SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "command -v rsync" >/dev/null 2>&1; then
    echo "rsync not found on remote. Attempting to install..."
    $SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "apt-get update && apt-get install -y rsync || yum install -y rsync || apk add rsync"
fi

# 3. Copy site files and deployment config
# We run this from the deploy/ directory, copying the parent directory contents
echo "Copying files..."
if command -v rsync >/dev/null 2>&1 && $SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "command -v rsync" >/dev/null 2>&1; then
    # We use -e to specify the ssh command including sshpass
    eval rsync -avz --progress \
        -e \"$RSYNC_SSH_CMD\" \
        --exclude '.git/' \
        --exclude '.idea/' \
        --exclude '.cursor/' \
        --exclude 'terminals/' \
        ./../ \"$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/\"
else
    echo "rsync not available on both sides, falling back to scp..."
    $SCP_CMD -r ../* "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
fi

# 4. Check for SSL certificates on remote
echo "Checking for SSL certificates on remote..."
$SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "[ -f $REMOTE_DIR/server.crt ] && [ -f $REMOTE_DIR/server.key ]"
if [ $? -ne 0 ]; then
    echo "WARNING: server.crt or server.key not found in $REMOTE_DIR on the remote host."
fi

# 5. Start the site using Docker Compose
echo "Starting site with Docker Compose..."
$SSH_CMD "$REMOTE_USER@$REMOTE_HOST" "
    cd $REMOTE_DIR/deploy
    docker compose down >/dev/null 2>&1 || true
    docker compose up -d
"

if [ $? -eq 0 ]; then
    echo "---------------------------------------------------"
    echo "Deployment successful!"
    echo "Site should be available at https://$REMOTE_HOST"
    echo "---------------------------------------------------"
else
    echo "---------------------------------------------------"
    echo "Deployment failed! Please check the output above."
    echo "---------------------------------------------------"
    exit 1
fi
