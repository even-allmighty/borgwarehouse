#!/bin/bash

set -e

CONFIG_DIR="/app/config"

print_green() { echo -e "\e[92m$1\e[0m"; }
print_red()   { echo -e "\e[91m$1\e[0m"; }

# 1. Give the current UID:GID a passwd entry

# The container runs as whatever UID:GID the runtime hands us, so that UID has
# no entry in /etc/passwd and /etc/passwd is not writable. ssh-keygen and sshd
# both refuse to work without one, so libnss-wrapper serves a fake entry from
# files we write to the tmpfs.
create_dummy_passwd() {
  local current_uid current_gid
  current_uid=$(id -u)
  current_gid=$(id -g)

  print_green "Creating dummy passwd file for borgwarehouse (uid: $current_uid, gid: $current_gid)"

  mkdir -p "$BORG_BASE_DIR"

  echo "borgwarehouse:x:$current_uid:$current_gid:borgwarehouse gecos:$BORG_BASE_DIR:/bin/bash" >/tmp/passwd
  echo "borgwarehouse:x:$current_gid:" >/tmp/group
}

ssh_keygen_with_nss() {
  LD_PRELOAD="libnss_wrapper.so" NSS_WRAPPER_PASSWD="/tmp/passwd" NSS_WRAPPER_GROUP="/tmp/group" \
    ssh-keygen "$@"
}

# 2. Check volume is mounted and writable

# Detect a real mount (named volume or bind mount) via /proc/mounts. #615
is_mounted() {
  grep -q " $1 " /proc/mounts
}

check_volume() {
  local dir=$1
  local name=$2

  if ! is_mounted "$dir"; then
    print_red "[ERROR] Volume '$name' is not mounted. Expected path: $dir"
    print_red "        Check the volumes section in your docker-compose.yml."
    exit 1
  fi

  # Nothing can be chowned from here: the container is unprivileged and the
  # root filesystem is read-only, so the host has to get the ownership right.
  if [ ! -w "$dir" ]; then
    print_red "[ERROR] Volume '$name' ($dir) is not writable by UID=$(id -u) GID=$(id -g)."
    print_red "        Fix it on the host: chown -R $(id -u):$(id -g) <your-host-path-for-$name>"
    exit 1
  fi
}

# 3. Generate SSH host keys if needed

# /etc/ssh belongs to the read-only image, so the host keys live in the ssh
# volume and are wired up through a config snippet included by sshd_config.
# Generating them by type (instead of ssh-keygen -A, which only writes to
# /etc/ssh) keeps existing keys untouched.
init_ssh_server() {
  mkdir -p "$SSH_HOST_KEYS_DIR"
  chmod 700 "$SSH_HOST_KEYS_DIR"

  if [ ! -f "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" ] \
     || [ ! -f "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" ] \
     || [ ! -f "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" ]; then
    print_green "Generating missing SSH host keys..."
    [ -f "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" ] ||
      ssh_keygen_with_nss -t rsa -b 4096 -f "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" -N ""
    [ -f "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" ] ||
      ssh_keygen_with_nss -t ecdsa -f "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" -N ""
    [ -f "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" ] ||
      ssh_keygen_with_nss -t ed25519 -f "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" -N ""
  fi

  chmod 600 "$SSH_HOST_KEYS_DIR"/ssh_host_*_key
  chmod 644 "$SSH_HOST_KEYS_DIR"/ssh_host_*_key.pub

  cat >/tmp/ssh_dynamic.conf <<-EOF
	# Hostkeys
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_rsa_key
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_ed25519_key

	Match User borgwarehouse
	  AuthorizedKeysFile $AUTHORIZED_KEYS_FILE
EOF
}

# 4. Setup the ssh volume and authorized_keys

# A chmod on a mount point fails as soon as the host directory belongs to
# someone else, and the errors that follow (sshd refusing the keys, borg unable
# to write) say nothing about the real cause. Report the mode, try to fix it,
# and if that is refused print the commands to run on the host.
check_mount_mode() {
  local dir=$1
  local name=$2
  local desired=$3
  local current
  current=$(stat -c "%a" "$dir" 2>/dev/null || echo "000")

  print_green "Checking $name volume permissions: $dir (current: $current, desired: $desired)"

  if [ "$current" = "$desired" ]; then
    return
  fi

  print_red "The $name volume has incorrect permissions: $current (expected: $desired)"
  print_green "Attempting to fix permissions..."

  if chmod "$desired" "$dir" 2>/dev/null; then
    print_green "Successfully set permissions to $desired on $dir"
  else
    print_red "[ERROR] Cannot set permissions on the $name volume!"
    print_red "        Please run the following commands on the host system:"
    print_red "          sudo chmod $desired $dir"
    print_red "          sudo chown $(id -u):$(id -g) $dir"
    exit 1
  fi
}

setup_ssh_directory() {
  check_mount_mode "$SSH_MOUNT_DIR" "ssh" 700

  # The client keys of the repositories are kept in a sub-directory so the
  # volume root can stay 700 whatever the host created it with.
  mkdir -p "$SSH_CLIENT_DIR"
  chmod 700 "$SSH_CLIENT_DIR"
}

# The repositories are only ever read by borg over ssh, so 700 is the default.
# Setups that share the pool with another service (a host backup agent, a
# monitoring job) can relax it with REPOS_PERMISSIONS.
setup_repos_directory() {
  check_mount_mode "$REPOS_DIR" "repos" "${REPOS_PERMISSIONS:-700}"
}

setup_authorized_keys() {
  if [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
    print_green "Creating authorized_keys file..."
    touch "$AUTHORIZED_KEYS_FILE"
  fi
  chmod 600 "$AUTHORIZED_KEYS_FILE"
}

# 5. Read SSH fingerprints

get_SSH_fingerprints() {
  print_green "Getting SSH fingerprints..."
  RSA_FINGERPRINT=$(ssh_keygen_with_nss -lf "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" | awk '{print $2}')
  ED25519_FINGERPRINT=$(ssh_keygen_with_nss -lf "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" | awk '{print $2}')
  ECDSA_FINGERPRINT=$(ssh_keygen_with_nss -lf "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" | awk '{print $2}')
  export SSH_SERVER_FINGERPRINT_RSA="$RSA_FINGERPRINT"
  export SSH_SERVER_FINGERPRINT_ED25519="$ED25519_FINGERPRINT"
  export SSH_SERVER_FINGERPRINT_ECDSA="$ECDSA_FINGERPRINT"
}

# 6. Check secrets

check_env() {
  if [ -z "$CRONJOB_KEY" ]; then
    CRONJOB_KEY=$(openssl rand -base64 32)
    print_green "CRONJOB_KEY not found or empty. Generating a random key..."
    export CRONJOB_KEY
  fi

  if [ -z "$NEXTAUTH_SECRET" ]; then
    NEXTAUTH_SECRET=$(openssl rand -base64 32)
    print_green "NEXTAUTH_SECRET not found or empty. Generating a random key..."
    export NEXTAUTH_SECRET
  fi
}

# Run

create_dummy_passwd
check_env
check_volume "$SSH_MOUNT_DIR" ".ssh"
check_volume "$REPOS_DIR"     "repos"
check_volume "$CONFIG_DIR"    "config"
init_ssh_server
setup_ssh_directory
setup_repos_directory
setup_authorized_keys
get_SSH_fingerprints

print_green "Successful initialization. BorgWarehouse is ready !"
exec supervisord -c /app/supervisord.conf
