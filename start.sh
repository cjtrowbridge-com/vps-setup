#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Preconditions: must be root
###############################################################################
if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root" >&2
  exit 1
fi

###############################################################################
# Determine the /home directory to use for host bind mounts
###############################################################################
mapfile -t HOME_ENTRIES < <(ls -1 /home)
if [[ ${#HOME_ENTRIES[@]} -eq 1 ]]; then
  HOME_USER="${HOME_ENTRIES[0]}"
else
  read -rp "Which user directory under /home should be used? " HOME_USER
fi
HOME_DIR="/home/${HOME_USER}"
if [[ ! -d "$HOME_DIR" ]]; then
  echo "Error: $HOME_DIR does not exist" >&2
  exit 1
fi

###############################################################################
# One‑time Docker install (APT, rootful) – optional prompt
###############################################################################
if ! command -v docker >/dev/null 2>&1; then
  read -rp "Run one‑time Docker installation? [y/N]: " ans
  if [[ $ans =~ ^[Yy]$ ]]; then
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME:-$VERSION_CODENAME}) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin

    docker run --rm hello-world
  fi
else
  echo "Docker already installed – skipping installation." >&2
fi

###############################################################################
# Paths, users, permissions
###############################################################################
NAS_BASE="/var/containers"
DOCKER_USER="docker"
DOCKER_GROUP="docker"

mkdir -p "$NAS_BASE"/{ollama,sd,comfy}

if ! id "$DOCKER_USER" &>/dev/null; then
  groupadd --system "$DOCKER_GROUP"
  useradd  --system --no-create-home --shell /usr/sbin/nologin \
           --gid "$DOCKER_GROUP" "$DOCKER_USER"
fi

USER_ID=$(id -u "$DOCKER_USER")
GROUP_ID=$(getent group "$DOCKER_GROUP" | cut -d: -f3)

chown -R "$USER_ID:$GROUP_ID" "$NAS_BASE"
chmod -R g+rwX "$NAS_BASE"

###############################################################################
# Generic idempotent helper
###############################################################################
create_or_start() {
  local name="$1"; shift

  # Already RUNNING → skip
  if docker ps   --filter "name=^${name}\$" --format '{{.Names}}' | grep -q "^${name}\$"; then
    echo "✅ $name is already running – skipped."
    return
  fi

  # Exists but STOPPED → start
  if docker ps -a --filter "name=^${name}\$" --format '{{.Names}}' | grep -q "^${name}\$"; then
    echo "🔄 Starting $name"
    docker start "$name"
    return
  fi

  # Create & run
  echo "🚀 Creating $name"
  docker run -d \
    --name "$name" \
    --network bridge \
    --restart unless-stopped \
    "$@"
}

###############################################################################
# Container deployments
###############################################################################

### Portainer UI ----------------------------------------------------------
docker volume create portainer_data >/dev/null
create_or_start portainer \
  -p 9443:9443 \
  -p 8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:lts

### OpenWebUI -------------------------------------------------------------
# This assumes ollama is running on a separate ai server
create_or_start openwebui \
  -p 3000:8080 \
  -e OLLAMA_BASE_URL=http://docker-ai:11434 \
 ghcr.io/open-webui/open-webui:latest

### Dashy -----------------------------------------------------------------
DASHY_CONF="$HOME_DIR/docker/dashy/public/conf.yml"
DASHY_ICONS="$HOME_DIR/docker/dashy/icons"
mkdir -p "$(dirname "$DASHY_CONF")" "$DASHY_ICONS"

create_or_start dashy \
  -p 8088:8080 \
  -v "$DASHY_CONF:/app/public/conf.yml" \
  -v "$DASHY_ICONS:/app/public/item-icons/icons" \
  lissy93/dashy:latest

### Jellyfin --------------------------------------------------------------
HOST_CONFIG_DIR="/srv/jellyfin/config"
HOST_CACHE_DIR="/srv/jellyfin/cache"
HOST_MEDIA_DIR="/var/nas/Library/Entertainment"
mkdir -p "$HOST_CONFIG_DIR" "$HOST_CACHE_DIR"

create_or_start jellyfin \
  -p 8096:8096 \
  -p 8920:8920 \
  --user "$USER_ID:$GROUP_ID" \
  -v "$HOST_CONFIG_DIR:/config" \
  -v "$HOST_CACHE_DIR:/cache" \
  -v "$HOST_MEDIA_DIR:/media" \
  --group-add 1001 \
  jellyfin/jellyfin:latest

### GitLab ----------------------------------------------------------------
docker volume create gitlab_config
docker volume create gitlab_data

create_or_start gitlab \
  -p 8929:8929 \
  -p 2222:22 \
  -p 8090:8090 \
  -e GITLAB_OMNIBUS_CONFIG="external_url 'http://localhost:8929'; gitlab_rails['gitlab_shell_ssh_port'] = 2222; pages_external_url 'http://localhost:8090'; gitlab_pages['enable'] = true;" \
  -v gitlab_config:/etc/gitlab \
  -v gitlab_data:/var/opt/gitlab \
  gitlab/gitlab-ce:latest


### Pi Hole
# Use a named volume to persist Pi-hole configuration
docker volume create pihole_config

create_or_start pihole \
  -p 8053:80 \
  -p 5353:53/tcp \
  -p 5353:53/udp \
  -e TZ="America/Los_Angeles" \
  -e PIHOLE_DNS_="1.1.1.1;1.0.0.1" \
  -v pihole_config:/etc/pihole \
  --cap-add=NET_ADMIN \
  pihole/pihole:latest

### MeTube ---------------------------------------------------------------
# Create the downloads directory if needed
mkdir -p /var/nas/Private/Downloads/Metube
chown "$USER_ID:$GROUP_ID" /var/nas/Private/Downloads/Metube

create_or_start metube \
  -p 8081:8081 \
  --user "$USER_ID:$GROUP_ID" \
  -v /var/nas/Private/Downloads/Metube:/downloads \
  ghcr.io/alexta69/metube

### JupyterLab (git & scheduler plugins, pinned <4) --------------------
# Always rebuild the image so pinned package versions take effect
echo "🛠️  Building my-jupyter image"
docker build -t my-jupyter "$(dirname "$0")/jupyter"

# Recreate the container if it already exists so the new image is used
if docker ps -a --filter "name=^jupyter$" --format '{{.Names}}' | grep -q '^jupyter$'; then
  docker rm -f jupyter
fi

create_or_start jupyter \
  -p 8888:8888 \
  my-jupyter

###############################################################################
# Friendly summary
###############################################################################
cat <<EOF

Access URLs
-----------
• Portainer UI : https://<host>:9443
• OpenWebUI    : http://<host>:3000
• Dashy        : http://<host>:8088
• Jellyfin     : http://<host>:8096  (host network)
• Metube       : http://<host>:8081
• JupyterLab   : http://<host>:8888

EOF
