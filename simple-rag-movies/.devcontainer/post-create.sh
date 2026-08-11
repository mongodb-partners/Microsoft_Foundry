#!/usr/bin/env bash
# Installs the tools that are not provided by devcontainer features:
#   - MongoDB Atlas CLI (via the official .deb; codename-independent, works on amd64/arm64)
#   - MongoDB Database Tools (mongorestore) - used to load ONLY sample_mflix, not the full sample set
#   - pymongo + dnspython (used by atlas-verify.py)
#   - Bicep (used by azure-deploy.ps1)
set -euo pipefail

ATLAS_VERSION="1.56.0"
TOOLS_VERSION="100.17.0"

echo ">>> Installing MongoDB Atlas CLI ${ATLAS_VERSION} ..."
arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64) atlas_url="https://fastdl.mongodb.org/mongocli/mongodb-atlas-cli_${ATLAS_VERSION}_linux_x86_64.deb" ;;
    arm64) atlas_url="https://fastdl.mongodb.org/mongocli/mongodb-atlas-cli_${ATLAS_VERSION}_linux_arm64.deb" ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
tmp="$(mktemp --suffix=.deb)"
curl -fsSL -o "$tmp" "$atlas_url"
sudo apt-get update -y
sudo apt-get install -y "$tmp"
rm -f "$tmp"
atlas --version

echo ">>> Installing MongoDB Database Tools (mongorestore) ${TOOLS_VERSION} ..."
. /etc/os-release
case "${VERSION_ID:-}" in
    24.04) tools_plat="ubuntu2404" ;;
    22.04) tools_plat="ubuntu2204" ;;
    *)     tools_plat="ubuntu2204" ;;
esac
case "$arch" in
    amd64) tools_arch="x86_64" ;;
    arm64) tools_arch="arm64" ;;
esac
tmp2="$(mktemp --suffix=.deb)"
curl -fsSL -o "$tmp2" "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-${tools_plat}-${tools_arch}-${TOOLS_VERSION}.deb"
sudo apt-get install -y "$tmp2"
rm -f "$tmp2"
mongorestore --version | head -1

echo ">>> Installing Python dependencies for verification ..."
python -m pip install --quiet --disable-pip-version-check pymongo dnspython

echo ">>> Ensuring Bicep is installed for the Azure CLI ..."
az bicep install || true

cat <<'EOF'

============================================================
 Ready. In the PowerShell terminal, run ONE command:

     ./scripts/setup-and-deploy.ps1

 It prompts you to log in to Azure and MongoDB Atlas, then
 sets up Atlas + Azure + the Foundry agent end to end.
============================================================
EOF
