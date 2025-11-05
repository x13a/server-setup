#!/usr/bin/env bash
set -eEuo pipefail
trap 'echo "err: $BASH_COMMAND on line $LINENO" >&2' ERR

BASE_DIR="$(dirname "$(realpath "$0")")"

declare -A VARS
declare -A DEFAULTS

VARS[username]="$(whoami)"
VARS[ssh_port]=""
DEFAULTS[ssh_port]="10101"

# ============================
# Helpers
# ============================

is_root() {
    [ "$(id -u)" -eq 0 ]
}

# ============================
# User management
# ============================

prompt_username() {
    local username
    read -rp "enter new username: " username
    [ -z "$username" ] && { echo "err: username cannot be empty, exit" >&2; exit 1; }
    VARS[username]="$username"
}

create_user() {
    local username="${VARS[username]}"
    if ! id "$username" &>/dev/null; then
        adduser --gecos "" "$username"
        usermod -aG sudo "$username"
        echo "[+] user '$username' created and added to sudo group"
    fi
    local sudoers_file="/etc/sudoers.d/$username"
    echo "$username ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 440 "$sudoers_file"
}

switch_to_user() {
    local username="${VARS[username]}"
    local script_path src_base user_home dest_dir script_name
    script_path="$(realpath "$0")" || { echo "err: cannot resolve script path" >&2; exit 1; }
    src_base="$(basename "$BASE_DIR")"
    script_name="$(basename "$script_path")"
    user_home=$(eval echo "~$username")
    dest_dir="$user_home/$src_base"
    mkdir -p "$dest_dir"
    cp -a "$BASE_DIR/." "$dest_dir/"
    chown -R "$username:$username" "$dest_dir"
    if [[ "$BASE_DIR" == /root/* ]]; then
        rm -rf "$BASE_DIR"
    fi
    echo "[*] switching to user '$username'..."
    exec su - "$username" -c "export SWITCHED=1; bash '$dest_dir/$script_name'"
}

rm_sudoers() {
    local username="$1"
    sudo rm -f "/etc/sudoers.d/$username"
}

# ============================
# SSH configuration
# ============================

configure_ssh() {
    local port
    add_ssh_pub_key
    port="$(sudo sshd -G 2>/dev/null | awk '/^port / {print $2}')"
    if [ "$port" = "22" ]; then
        port="${DEFAULTS[ssh_port]}"
        echo "[*] SSH port set to $port"
    fi
    VARS[ssh_port]="$port"
    deploy_ssh_config
}

add_ssh_pub_key() {
    local ssh_dir="$HOME/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"
    local pub_key
    read -rp "enter your SSH public key, press enter to skip: " pub_key
    if [ -z "$pub_key" ]; then
        return 0
    fi
    install -d -m 700 "$ssh_dir"
    install -m 600 /dev/null "$authorized_keys"
    if grep -qxF "$pub_key" "$authorized_keys" 2>/dev/null; then
        return 0
    fi
    echo "$pub_key" >> "$authorized_keys"
    echo "[+] SSH public key added successfully"
}

deploy_ssh_config() {
    local username="${VARS[username]}"
    local ssh_port="${VARS[ssh_port]}"
    local target="/etc/ssh/sshd_config.d/srv.conf"
    local template="$BASE_DIR/$target"
    local tmp_file
    [[ -f "$template" ]] || { echo "err: missing SSH template $template" >&2; exit 1; }
    echo "[*] deploying SSH config for user '$username' on port '$ssh_port'..."
    tmp_file=$(mktemp)
    sed \
        -e "s/${DEFAULTS[ssh_port]}/$ssh_port/" \
        -e "s/SOME_USERNAME/$username/" \
        "$template" > "$tmp_file"
    sudo install -m 600 -o root -g root "$tmp_file" "$target"
    rm -f "$tmp_file"
    echo "[+] SSH config deployed to $target"
}

# ============================
# UFW & Fail2Ban
# ============================

configure_ufw() {
    echo "[*] configuring UFW rules..."
    sudo ufw limit "${VARS[ssh_port]}/tcp"
    sudo ufw --force enable
    echo "[+] UFW configured"
}

setup_fail2ban() {
    local target_dir="/etc/fail2ban/jail.d"
    local target_file="$target_dir/sshd.local"
    local template="$BASE_DIR/$target_file"
    local tmp_file
    [[ -f "$template" ]] || { echo "err: missing fail2ban template $template" >&2; exit 1; }
    echo "[*] setuping fail2ban..."
    tmp_file=$(mktemp)
    sed \
        -e "s/${DEFAULTS[ssh_port]}/${VARS[ssh_port]}/" \
        "$template" > "$tmp_file"
    sudo install -D -m 644 -o root -g root "$tmp_file" "$target_file"
    rm -f "$tmp_file"
    sudo systemctl enable fail2ban
    echo "[+] fail2ban config deployed to $target_file"
}

# ============================
# Docker
# ============================

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "[*] docker already installed"
        return 0
    fi
    echo "[*] installing docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm -f get-docker.sh
    sudo groupadd -f docker
    sudo usermod -aG docker "${VARS[username]}"
    echo "[+] docker installed"
}

set_docker_limits() {
    local gen_limits="/usr/local/bin/gen-docker-memory-limits.sh"
    local svc="/etc/systemd/system/docker-memory-limits.service"
    local d_file="/etc/systemd/system/docker.service.d/override.conf"
    [[ -f "$BASE_DIR/$gen_limits" ]] || { echo "err: missing $gen_limits" >&2; exit 1; }
    [[ -f "$BASE_DIR/$svc" ]] || { echo "err: missing $svc" >&2; exit 1; }
    [[ -f "$BASE_DIR/$d_file" ]] || { echo "err: missing $d_file" >&2; exit 1; }
    echo "[*] setting docker limits..."
    sudo install -D -m 755 -o root -g root "$BASE_DIR/$gen_limits" "$gen_limits"
    sudo install -D -m 644 -o root -g root "$BASE_DIR/$svc" "$svc"
    sudo install -D -m 644 -o root -g root "$BASE_DIR/$d_file" "$d_file"
    sudo systemctl daemon-reload
    sudo systemctl enable --now docker-memory-limits.service
    echo "[+] docker limits applied"
}

# ============================
# System update
# ============================

update_sys() {
    echo "[*] updating system..."
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install fail2ban ufw -y
    sudo apt-get autoremove -y
    echo "[+] system updated"
}

# ============================
# Main
# ============================

main() {
    if is_root && [ -z "${SWITCHED:-}" ]; then
        echo "[*] running as root"
        prompt_username
        create_user
        switch_to_user
    fi
    local username="${VARS[username]}"
    if [ "${SWITCHED:-}" = "1" ]; then
        export TRAP_USER="$username"
        trap 'rm_sudoers "$TRAP_USER"' EXIT
    fi
    echo "[*] running as $username"
    update_sys
    configure_ssh
    configure_ufw
    setup_fail2ban
    install_docker
    set_docker_limits
    echo "[+] done, reboot"
}

main "$@"
