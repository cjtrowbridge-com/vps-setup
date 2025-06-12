# vps-setup

This repo provides a single `start.sh` script that provisions a set of Docker
services for a personal server or lab. It installs containers for management
UI, dashboards, media streaming and a JupyterLab environment with Git
integration.

## Usage
1. Log in as **root** and run `./start.sh`.
2. If more than one directory exists under `/home`, the script will prompt
   which user directory to use for bind mounts.
3. The script optionally installs Docker if it is not already present.
4. Containers are then created or started as needed. Existing containers are
   reused so the script can be run multiple times safely.

At completion a list of URLs for each service will be displayed.

## What the script does
- Creates `/var/containers/` directories with the correct permissions for
  persistent Docker data.
- Ensures a system user and group named `docker` exist and owns these
  directories.
- Defines a helper function `create_or_start` that starts a container if it
  already exists or creates it otherwise.
- Deploys the following containers:
  - **Portainer** – web UI for managing Docker itself.
  - **OpenWebUI** – interface for connecting to an Ollama AI server.
  - **Dashy** – customizable dashboard using files under the chosen `/home`
    directory.
  - **Jellyfin** – media streaming server with volumes under `/srv/jellyfin`.
  - **GitLab** – self-hosted Git service with named volumes.
  - **Pi-hole** – DNS filtering service.
  - **JupyterLab** – built from `jupyter/Dockerfile`; includes the
    `jupyterlab-git` and `jupyterlab_scheduler` extensions so notebooks can be
    version controlled and scheduled directly from the web interface.

The Jupyter image is built automatically the first time `start.sh` runs. After
setup, visit the printed URLs (e.g. `https://<host>:9443` for Portainer) to use
each service.

## Customization
Adjust environment variables such as ports or directory paths by editing
`start.sh` before running it. The script is intended to be straightforward and
idempotent so it can be rerun whenever you modify the configuration or after
reboots.
