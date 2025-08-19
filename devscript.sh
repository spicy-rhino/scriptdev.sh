#!/bin/bash

# Baseline v4 - Full Stack Setup Script for Orange Pi 5+ / RPi5 (Ubuntu 24.04.2 LTS)
# Services: TAK Server, OwnCloud (Docker), MediaMTX, Mumble Server

set -euo pipefail
trap 'echo "[!] ERROR on line $LINENO: Command \"$BASH_COMMAND\" failed" >&2' ERR

LOG_DIR="/tmp/fullstack_logs"
mkdir -p "$LOG_DIR"
echo "[+] Log directory initialized at $LOG_DIR"

# Figure out the actual interactive user and home directory
if [ "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
else
    ACTUAL_USER="$(whoami)"
fi
USER_HOME=$(eval echo "~$ACTUAL_USER")

# === 0. Update System First ===
echo "[+] Updating and upgrading system packages (this may take a while)..."
sudo apt update -y | tee "$LOG_DIR/apt_update.log"
sudo apt upgrade -y | tee "$LOG_DIR/apt_upgrade.log"
echo "[+] System packages updated and upgraded."

# === 1. Cleanup Previous Installations and Artifacts ===
echo "[+] Cleaning up previous installations and residual files..."
sudo systemctl stop takserver || true
sudo systemctl disable takserver || true
sudo systemctl stop mumble-server || true
sudo systemctl disable mumble-server || true
sudo docker rm -f owncloud || true
sudo docker container prune -f || true
sudo docker image rm -f owncloud:latest || true

sudo rm -rf /opt/tak /etc/tak /var/tak || true
sudo rm -rf /etc/mumble-server.ini /var/lib/mumble-server || true
sudo rm -rf "$USER_HOME/installTAK" mediamtx* mediamtx.log "$USER_HOME/mediamtx.log" || true
sudo rm -f "$USER_HOME"/mediamtx_*.tar.gz || true

sudo apt-mark unhold ffmpeg v4l-utils containerd.io || true
sudo apt purge -y takserver mumble-server docker-ce docker-ce-cli containerd.io containerd || true
sudo apt autoremove -y || true
sudo rm -rf "$LOG_DIR"/*
echo "[+] Cleanup complete."

# === 2. Install Common Dependencies ===
echo "[+] Installing dependencies..."
sudo apt install --allow-change-held-packages -y \
  git curl v4l-utils ffmpeg docker.io containerd mumble-server \
  openssh-server openssh-client ssh net-tools dialog dos2unix | tee "$LOG_DIR/apt_install.log"
echo "[+] Dependency installation complete."

# === 3. Enable and Start Docker, SSH, and MediaMTX Services ===
echo "[+] Enabling and starting Docker and SSH services..."
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable ssh
sudo systemctl start ssh
sudo systemctl status docker --no-pager
sudo systemctl status ssh --no-pager

# === 4. Pre-configure Mumble for non-interactive setup ===
echo "[+] Preconfiguring Mumble server (no blocking prompts)..."
sudo debconf-set-selections <<EOF
mumble-server    mumble-server/autostart  boolean true
EOF

# === 5. Clone and Prep installTAK ===
echo "[+] Cloning TAK install script from GitHub..."
cd "$USER_HOME"
git clone https://github.com/myTeckNet/installTAK.git | tee "$LOG_DIR/tak_clone.log"
sudo chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/installTAK"
sudo chmod u+w "$USER_HOME/installTAK"

# === 6. Set Home Dir Permissions ===
echo "[+] Fixing home directory permissions for SFTP..."
sudo chown -R "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME"
sudo chmod 755 "$USER_HOME"

# === 7. Prompt for TAK File Transfer ===
echo "[!] Manual Step: SCP the following files into $USER_HOME/installTAK before continuing:"
echo "    - TAKSERVER-PUBLIC-GPG.key"
echo "    - TAKSERVER_5.4RELEASE19_ALL.deb"
echo "    - DEB_POLICY.POL"
echo "Use: scp <files> $ACTUAL_USER@<OrangePi-IP>:$USER_HOME/installTAK"
echo "Press [Enter] once the files have been transferred."
read -r

# === 8. Install TAK Server with tty support ===
echo "[+] Launching TAK Server installer in interactive tty..."
cd "$USER_HOME/installTAK" || { echo "[!] Failed to access installTAK directory"; exit 1; }
sudo script -q -c "./installTAK takserver_5.4-RELEASE19_all.deb" /dev/null | tee "$LOG_DIR/tak_install.log"
cd "$USER_HOME"
echo "[+] TAK Server installation complete."

# === 9. Copy TAK certs to user directory for SFTP (improved v3.1 logic) ===
echo "[+] Copying TAK Server certs for user SFTP..."
for f in FedCA.pem webadmin.p12 enrollmentDP.zip enrollmentDP-QUIC.zip; do
  if [ -f "/opt/tak/certs/files/$f" ]; then
    sudo cp "/opt/tak/certs/files/$f" "$USER_HOME/$f"
    sudo chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/$f"
    echo "    Copied $f from /opt/tak/certs/files/"
  elif [ -f "/root/$f" ]; then
    sudo cp "/root/$f" "$USER_HOME/$f"
    sudo chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/$f"
    echo "    Copied $f from /root/"
  else
    echo "[!] $f not found in /opt/tak/certs/files/ or /root/"
  fi
done

# === 10. OwnCloud via Docker ===
echo "[+] Deploying OwnCloud container on port 80..."
sudo docker run -d --restart unless-stopped -p 80:80 --name=owncloud owncloud:latest | tee "$LOG_DIR/owncloud_docker.log" || {
  echo "[!] Docker may not have started properly. Check daemon status." >&2
  exit 1
}
echo "[+] OwnCloud deployed. Access it at http://<OrangePi-IP>"

# === 11. MediaMTX Setup and Systemd Service ===
echo "[+] Downloading and installing MediaMTX (stable ARM64)..."
cd "$USER_HOME"
wget https://filesamples.com/samples/video/mp4/sample_640x360.mp4 -O sample.mp4
curl -Lo mediamtx.tar.gz https://github.com/bluenviron/mediamtx/releases/download/v1.12.3/mediamtx_v1.12.3_linux_arm64.tar.gz | tee "$LOG_DIR/mediamtx_download.log"
tar -xzf mediamtx.tar.gz | tee "$LOG_DIR/mediamtx_extract.log"
rm -f mediamtx.tar.gz
chmod +x "$USER_HOME/mediamtx"
sudo chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/mediamtx"

# Ensure mediamtx.yml allows all publishers by default
if [ -f "$USER_HOME/mediamtx.yml" ]; then
  # If an 'all_others:' path exists, convert it to 'all:' and set source to publisher
  sudo sed -i 's/^  all_others:.*/  all:\n    source: publisher/' "$USER_HOME/mediamtx.yml"
else
  # Create a minimal config that allows all publishers
  cat <<'EOF' | sudo tee "$USER_HOME/mediamtx.yml" >/dev/null
paths:
  all:
    source: publisher
EOF
  sudo chown "$ACTUAL_USER":"$ACTUAL_USER" "$USER_HOME/mediamtx.yml"
  sudo chmod 644 "$USER_HOME/mediamtx.yml"
fi

# --- Create a systemd service for MediaMTX ---
sudo tee /etc/systemd/system/mediamtx.service > /dev/null <<EOF
[Unit]
Description=MediaMTX
After=network.target

[Service]
Type=simple
User=$ACTUAL_USER
ExecStart=$USER_HOME/mediamtx
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mediamtx
sudo systemctl start mediamtx
echo "[+] MediaMTX installed and running as a service. Logs: $USER_HOME/mediamtx.log"

# === 12. Mumble Server Setup ===
echo "[+] Restarting Mumble service..."
sudo systemctl restart mumble-server | tee "$LOG_DIR/mumble_restart.log"

# === Completion ===
echo "[✓] Full compute stack deployed on Orange Pi 5 Plus:"
echo "    - TAK Admin UI: https://<OrangePi-IP>:8443"
echo "    - OwnCloud: http://<OrangePi-IP>"
echo "    - Mumble: port 64738 (adjust config as needed)"
echo "    - MediaMTX logs in $USER_HOME/mediamtx.log"
echo "    - TAK certs for SFTP: $USER_HOME/[FedCA.pem, webadmin.p12, enrollmentDP.zip, enrollmentDP-QUIC.zip]"
echo "    - All setup logs stored in $LOG_DIR"

exit 0
