#!/bin/bash
# Automated installer for searxng (Podman + systemd)
set -e

SERVICE_FILE="packaging/searxng.service"
SYSTEMD_DIR="/etc/systemd/system"
OPT_DIR="/opt/searxng"
CONFIG_DIR="$OPT_DIR/config"
DATA_DIR="$OPT_DIR/data"
SETTINGS_FILE="$CONFIG_DIR/settings.yml"

usage() {
  echo "Usage: $0 [--update]"
  echo "  --update  Only update service and image, do not recreate directories"
  exit 1
}

UPDATE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      UPDATE_ONLY=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# Robustness: check for required commands
if ! command -v podman >/dev/null 2>&1; then
  echo "Error: podman is not installed or not in PATH. Install it with: sudo dnf install -y podman" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemctl is not available. This installer requires systemd." >&2
  exit 1
fi

SYSTEMCTL="sudo systemctl"
SYSTEMD_TARGET="$SYSTEMD_DIR"

if [ $UPDATE_ONLY -eq 0 ]; then
  echo "Creating persistent directories under $OPT_DIR..."
  sudo mkdir -p "$CONFIG_DIR" "$DATA_DIR"
  sudo chown "$USER:$USER" "$OPT_DIR" -R
  echo "Copying example settings file..."
  if [ ! -f "$SETTINGS_FILE" ]; then
    cp examples/settings.yml "$SETTINGS_FILE"
    SECRET_KEY=`openssl rand -hex 32`
    sudo sed -i "s|^  secret_key: .*|  secret_key: \"${SECRET_KEY}\"|" "$SETTINGS_FILE"
    echo "Edit $SETTINGS_FILE to configure API endpoints and websearch keys."
  else
    echo "$SETTINGS_FILE already exists, skipping copy."
    echo "Edit $SETTINGS_FILE to configure API endpoints and websearch keys and restart searxng.service."
  fi
fi

if [ ! -f "$SYSTEMD_TARGET/searxng.service" ]; then
  echo "Installing searxng.service to $SYSTEMD_TARGET..."
  sudo mkdir -p "$SYSTEMD_TARGET"
  sudo cp "$SERVICE_FILE" "$SYSTEMD_TARGET/searxng.service"
  echo "Reloading systemd..."
  $SYSTEMCTL daemon-reload
else
  echo "searxng.service already installed, skipping copy."
  echo "Edit $SYSTEMD_TARGET/searxng.service if needed and restart searxng.service."
fi

echo "Pulling latest container image..."
sudo podman pull ghcr.io/searxng/searxng:latest

echo "Enabling and starting searxng.service..."
$SYSTEMCTL enable --now searxng.service

echo "Restarting searxng.service to apply changes..."
$SYSTEMCTL restart searxng.service

cat <<EOF

Installation complete!

- Service: searxng.service
- Persistent data: $OPT_DIR
- Config file: $SETTINGS_FILE
- Image: ghcr.io/searxng/searxng:latest (pulled during install)

To check status:
  $SYSTEMCTL status searxng.service
To view logs:
  sudo journalctl -u searxng.service -e

To update:
  $0 --update

EOF

# Healthcheck note (printed after installation summary)
HEALTHCHECK_SCRIPT="scripts/healthcheck.sh"
if [ -x "$HEALTHCHECK_SCRIPT" ]; then
  echo "To run healthcheck: bash $HEALTHCHECK_SCRIPT"
  bash scripts/healthcheck.sh
else
  echo "Healthcheck script not found. Quick test: curl -fsS http://localhost:8112/ || echo 'Service not responding'"
fi
