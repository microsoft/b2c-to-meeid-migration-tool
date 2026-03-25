#!/bin/bash
# Setup script to run ON the VM via Bastion SSH.
# Clones the repo and builds the app locally — no blob/storage access needed.
#
# Usage: bash Setup-Worker.sh [branch]
#
# Example:
#   bash Setup-Worker.sh                 # uses 'main' branch
#   bash Setup-Worker.sh main            # uses 'main' branch

set -euo pipefail

BRANCH="${1:-main}"
REPO_URL="https://github.com/microsoft/b2c-to-meeid-migration-tool.git"
DEPLOY_DIR="/opt/b2c-migration/app"
REPO_DIR="/opt/b2c-migration/repo"

echo "=== Cloning repo (branch: $BRANCH) ==="
sudo rm -rf "$REPO_DIR"
sudo mkdir -p "$REPO_DIR" "$DEPLOY_DIR"
sudo chown "$(whoami)" "$REPO_DIR" "$DEPLOY_DIR"

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"

echo "=== Building ==="
dotnet publish "$REPO_DIR/src/B2CMigrationKit.Console/B2CMigrationKit.Console.csproj" \
    --configuration Release \
    --output "$DEPLOY_DIR" \
    --nologo \
    --verbosity quiet

chmod +x "$DEPLOY_DIR/B2CMigrationKit.Console" 2>/dev/null || true

echo ""
echo "=== Setup complete ==="
echo "Copy your config file to: $DEPLOY_DIR/appsettings.json"
echo ""
echo "Then run migration:"
echo "  cd $DEPLOY_DIR"
echo "  ./B2CMigrationKit.Console harvest --config appsettings.json"
echo "  ./B2CMigrationKit.Console worker-migrate --config appsettings.json"
echo "  ./B2CMigrationKit.Console phone-registration --config appsettings.json"
