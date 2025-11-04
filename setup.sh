#!/usr/bin/env bash
set -eEuo pipefail
trap 'echo "error at $BASH_COMMAND on line $LINENO" >&2' ERR

DEFAULT_SSH_PORT="10101"
BASE_DIR="$(dirname "$(realpath "$0")")"

is_root() {
    [ "$(id -u)" -eq 0 ]
}

prompt_username() {
    local username
    read -rp "enter new username: " username
    if [ -z "$username" ]; then
        echo "error: username cannot be empty, exit" >&2
        exit 1
    fi
    echo "$username"
}

create_user() {
    local username="$1"
    if ! id "$username" &>/dev/null; then
        adduser --gecos "" "$username"
        usermod -aG sudo "$username"
        echo "user '$username' created and added to sudo group" >&2
    fi
    local sudoers_file="/etc/sudoers.d/$username"
    echo "$username ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 440 "$sudoers_file"
}

switch_to_user() {
    local username="$1"
    local script_path src_dir src_base user_home dest_dir script_name
    script_path="$(realpath "$0")" || { echo "cannot resolve script path"; exit 1; }
    src_dir="$(dirname "$script_path")"
    src_base="$(basename "$src_dir")"
    script_name="$(basename "$script_path")"
    user_home=$(eval echo "~$username")
    dest_dir="$user_home/$src_base"
    mkdir -p "$dest_dir"
    cp -a "$src_dir/." "$dest_dir/"
    chown -R "$username:$username" "$dest_dir"
    rm -rf "$src_dir"
    echo "switching to user '$username'..." >&2
    exec su - "$username" -c "export SWITCHED=1; bash '$dest_dir/$script_name'"
}

configure_ssh() {
    local username="$1"
    local port
    add_ssh_pub_key >&2
    port=$(sudo sshd -G 2>/dev/null | awk '/^port / {print $2}')
    if [ "$port" = "22" ]; then
        port="$DEFAULT_SSH_PORT"
        echo "SSH port set to $port" >&2
    fi
    deploy_ssh_config "$username" "$port" >&2
    echo "$port"
}

add_ssh_pub_key() {
    local ssh_dir="$HOME/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"
    local pub_key
    read -rp "enter your SSH public key, press enter to skip: " pub_key
    if [ -z "$pub_key" ]; then
        return 0
    fi
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi
    touch "$authorized_keys"
    if grep -qxF "$pub_key" "$authorized_keys" 2>/dev/null; then
        return 0
    fi
    echo "$pub_key" >> "$authorized_keys"
    chmod 600 "$authorized_keys"
    echo "SSH public key added successfully" >&2
}

deploy_ssh_config() {
    local username="$1"
    local ssh_port="$2"
    local target="/etc/ssh/sshd_config.d/srv.conf"
    local template="$BASE_DIR/$target"
    local tmp_file
    echo "deploying SSH config for user '$username' on port '$ssh_port'..." >&2
    tmp_file=$(mktemp)
    sed \
        -e "s/$DEFAULT_SSH_PORT/$ssh_port/" \
        -e "s/SOME_USERNAME/$username/" \
        "$template" > "$tmp_file"
    sudo cp "$tmp_file" "$target"
    sudo chown root:root "$target"
    sudo chmod 600 "$target"
    rm -f "$tmp_file"
    echo "SSH config deployed to $target" >&2
}

configure_ufw() {
    local ssh_port="$1"
    echo "configuring UFW rules..." >&2
    sudo ufw limit "$ssh_port/tcp"
    sudo ufw --force enable
}

setup_fail2ban() {
    local ssh_port="$1"
    local target_dir="/etc/fail2ban/jail.d"
    local target_file="$target_dir/sshd.local"
    local template="$BASE_DIR/$target_file"
    local tmp_file
    echo "setuping fail2ban..." >&2
    if [ ! -d "$target_dir" ]; then
        sudo mkdir -p "$target_dir"
        sudo chown root:root "$target_dir"
        sudo chmod 755 "$target_dir"
    fi
    tmp_file=$(mktemp)
    sed \
        -e "s/$DEFAULT_SSH_PORT/$ssh_port/" \
        "$template" > "$tmp_file"
    sudo cp "$tmp_file" "$target_file"
    sudo chown root:root "$target_file"
    sudo chmod 644 "$target_file"
    rm -f "$tmp_file"
    echo "fail2ban config deployed to $target_file" >&2
    sudo systemctl enable fail2ban
}

install_docker() {
    local username="$1"
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    echo "installing docker..." >&2
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm ./get-docker.sh
    sudo groupadd -f docker
    sudo usermod -aG docker "$username"
}

update_sys() {
    echo "updating system..." >&2
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install fail2ban ufw -y
    sudo apt-get autoremove -y
}

rm_sudoers() {
    local username="$1"
    sudo rm -f "/etc/sudoers.d/$username"
}

main() {
    if is_root && [ -z "${SWITCHED:-}" ]; then
        echo "running as root" >&2
        local new_user
        new_user="$(prompt_username)"
        create_user "$new_user"
        switch_to_user "$new_user" 
    fi
    local username ssh_port
    username="$(whoami)"
    if [ "${SWITCHED:-}" = "1" ]; then
        export TRAP_USER="$username"
        trap 'rm_sudoers "$TRAP_USER"' EXIT
    fi
    echo "running as $username" >&2
    update_sys
    ssh_port="$(configure_ssh "$username")"
    configure_ufw "$ssh_port"
    setup_fail2ban "$ssh_port"
    install_docker "$username"
    echo "done, reboot" >&2
}

main "$@"
