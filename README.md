# Ubuntu Server Bootstrap Script

This repository contains an automated **server setup and hardening script** written in Bash.  
It’s designed to quickly prepare a clean Ubuntu server for secure remote access and Docker-based workloads.

## Features

- **User Management**
  - Creates a new sudo-enabled user.
  - Automatically switches to the new user context.
  - Grants temporary passwordless `sudo` access during setup and removes it afterward.

- **SSH Configuration**
  - Prompts for your SSH public key and securely installs it.
  - Deploys a custom SSH configuration (`/etc/ssh/sshd_config.d/srv.conf`).
  - Changes the SSH port, which can be configured via the environment variable `SSH_PORT` (default: `10101`).
  - Ensures correct permissions for SSH directories and keys.

- **Firewall & Security**
  - Configures **UFW** to allow only SSH access on the configured port.
  - Installs and sets up **Fail2Ban** to protect against brute-force attacks.

- **Docker Installation**
  - Automatically installs the latest Docker version using the official script.
  - Adds the created user to the `docker` group.
  - Deploys custom Docker systemd overrides and memory limit service.

- **Swap Management**
	- Checks if a swap file exists; if not, creates one based on the configured size.
  - Swap size can be set via the environment variable `SWAP_SIZE` (e.g., `export SWAP_SIZE=2G`).
	- Enables the swap file and sets appropriate permissions.
	- Ensures the swap is persistent across reboots.

- **System Maintenance**
  - Updates and upgrades system packages.
  - Removes obsolete packages after setup.

## Usage

Clone repository to local directory:

```sh
git clone https://github.com/x13a/server-setup
```

Change directory to recently clonned repository:

```sh
cd server-setup
```

Run *setup.sh* file:

```sh
./setup.sh
```

## License

MIT
