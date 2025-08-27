#!/bin/bash

# Baseline v5 - Full Stack Setup Script for Orange Pi 5+ / RPi5 (Ubuntu 24.04.x LTS)
# Services: TAK Server, OwnCloud (Docker), MediaMTX, Mumble Server

wget https://filesamples.com/samples/video/mp4/sample_640x360.mp4 -O sample.mp4

sudo curl -fsSL https://raw.githubusercontent.com/spicy-rhino/script.sh/main/99-radio-usb-static.yaml -o /etc/netplan/99-radio-usb-static.yaml

sudo netplan apply

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

sudo install -d -o mumble-server -g mumble-server -m 750 /var/lib/mumble-server
sudo test -f /etc/mumble-server.ini || sudo touch /etc/mumble-server.ini
sudo chown root:root /etc/mumble-server.ini
sudo systemctl enable --now mumble-server

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

###############################################
# Section 11 — MediaMTX setup and systemd service
###############################################
set -euo pipefail

echo "==> [Section 11] Installing MediaMTX and systemd unit"

# ===== Config =====
MTX_VERSION="${MTX_VERSION:-v1.12.3}"   # override by: export MTX_VERSION=v1.12.3
BIN_NAME="mediamtx"

# ===== Resolve user & home (support sudo and direct run) =====
U="${SUDO_USER:-$USER}"
HOME_DIR="$(eval echo "~$U")"
echo "[*] Target user: $U  HOME=$HOME_DIR"

# ===== Detect arch -> choose correct tarball =====
arch="$(uname -m)"
case "$arch" in
  aarch64|arm64)  MTX_TAR="mediamtx_${MTX_VERSION}_linux_arm64.tar.gz" ;;
  x86_64|amd64)   MTX_TAR="mediamtx_${MTX_VERSION}_linux_amd64.tar.gz" ;;
  *)
    echo "[-] Unsupported architecture: $arch"
    exit 1
    ;;
esac
MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/${MTX_TAR}"
echo "[*] Download: $MTX_URL"

# ===== Download & install to user's home =====
sudo -u "$U" bash -c "
  set -e
  cd \"$HOME_DIR\"
  rm -f \"$BIN_NAME\" mediamtx_*.tar.gz || true
  curl -fsSL -o \"$MTX_TAR\" \"$MTX_URL\"
  tar xzf \"$MTX_TAR\"
  # Move binary out of extracted folder to HOME
  mv mediamtx_*/* \"$HOME_DIR\" 2>/dev/null || true
  rmdir mediamtx_* 2>/dev/null || true
  rm -f \"$MTX_TAR\"
  chmod +x \"$HOME_DIR/$BIN_NAME\"
"

# ===== Create default config if missing; otherwise fix common YAML hiccup =====
if [ ! -f "$HOME_DIR/mediamtx.yml" ]; then
  echo "[*] Writing default $HOME_DIR/mediamtx.yml"
  sudo -u "$U" tee "$HOME_DIR/mediamtx.yml" >/dev/null <<'YAML'
logLevel: info

# Enable common servers
rtsp: yes
rtspTransports: [udp, multicast, tcp]
rtspEncryption: "no"
rtspAddress: :8554
rtpAddress: :8000
rtcpAddress: :8001

rtmp: yes
hls: yes
webrtc: yes
webrtcLocalUDPAddress: :8189
srt: yes

# Allow anonymous publish/read/playback by default
authMethod: internal
authInternalUsers:
- user: any
  pass:
  ips: []
  permissions:
  - action: publish
  - action: read
  - action: playback

# Defaults allow publishers
pathDefaults:
  source: publisher
  overridePublisher: yes

paths:
  all_others:
    source: publisher
YAML
else
  # Fix common copy/paste glitch where rtpAddress line gets merged into a comment
  sudo -u "$U" sed -i 's/rtspTransports.rtpAddress:/\nrtpAddress:/' "$HOME_DIR/mediamtx.yml" || true
fi

# ===== Install username-agnostic *templated* systemd unit =====
echo "[*] Installing /etc/systemd/system/mediamtx@.service"
sudo tee /etc/systemd/system/mediamtx@.service >/dev/null <<'UNIT'
[Unit]
Description=MediaMTX (%i)
After=network.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/home/%i
Environment=HOME=/home/%i
ExecStart=/home/%i/mediamtx /home/%i/mediamtx.yml
Restart=on-failure
RestartSec=2

# Optional hardening (uncomment if desired)
# NoNewPrivileges=yes
# PrivateTmp=yes
# ProtectSystem=full
# ProtectHome=read-only
# ReadWritePaths=/home/%i

[Install]
WantedBy=multi-user.target
UNIT

# Disable any old non-templated unit if present (ignore errors)
sudo systemctl disable --now mediamtx 2>/dev/null || true

# ===== Enable and start instance for current user =====
echo "[*] Enabling mediamtx@$U"
sudo systemctl daemon-reload
sudo systemctl enable --now "mediamtx@$U"

# ===== Quick status pointers =====
echo "[*] MediaMTX running as mediamtx@$U"
echo "    View logs:  sudo journalctl -u mediamtx@$U -f"
echo "    Test push:  ffmpeg -re -stream_loop -1 -i ~/sample.mp4 -c copy -an -fflags +genpts -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/test"

# === 12. Mumble Server Setup ===
echo "[+] Restarting Mumble service..."
sudo systemctl restart mumble-server | tee "$LOG_DIR/mumble_restart.log"

# === 13. RTSP Setup ===
CONFIG="/home/${SUDO_USER:-$USER}/mediamtx.yml"
sudo sed -i 's/^  all_others:.*/  all_others:\n    source: publisher/' "$CONFIG"
sudo systemctl restart "mediamtx@${SUDO_USER:-$USER}"

# === Completion ===
echo "[✓] Full compute stack deployed on Orange Pi 5 Plus:"
echo "    - TAK Admin UI: https://<OrangePi-IP>:8443"
echo "    - OwnCloud: http://<OrangePi-IP>"
echo "    - Mumble: port 64738 (adjust config as needed)"
echo "    - MediaMTX logs in $USER_HOME/mediamtx.log"
echo "    - TAK certs for SFTP: $USER_HOME/[FedCA.pem, webadmin.p12, enrollmentDP.zip, enrollmentDP-QUIC.zip]"
echo "    - All setup logs stored in $LOG_DIR"

exit 0
