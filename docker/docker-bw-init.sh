#!/bin/bash

set -e

# Fixed paths for mounted volumes
SSH_DIR="/data/ssh"
SSH_HOST_KEYS_DIR="/data/ssh_host_keys"
AUTHORIZED_KEYS_FILE="$SSH_DIR/authorized_keys"
REPOS_DIR="/data/repos"

print_green() {
  echo -e "\e[92m$1\e[0m";
}
print_red() { 
  echo -e "\e[91m$1\e[0m";
}

create_dummy_passwd() {
  # Create dummy passwd and group files for nss-wrapper
  # This is needed because ssh-keygen requires passwd entries
  local current_uid=$(id -u)
  local current_gid=$(id -g)

  print_green "Creating dummy passwd file for containeruser (uid: $current_uid, gid: $current_gid)"

  # Create passwd file
  echo "borgwarehouse:x:$current_uid:$current_gid:borgwarehouse gecos:/tmp/borgwarehouse:/bin/bash" >/tmp/passwd

  # Create group file
  echo "borgwarehouse:x:$current_gid:" >/tmp/group
}

init_ssh_server() {

  mkdir -p "$SSH_HOST_KEYS_DIR"
  chmod 700 "$SSH_HOST_KEYS_DIR"

  if [ ! -f "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" ]; then
    print_green "Generating SSH host keys..."

    # Create dummy passwd file for nss-wrapper
    create_dummy_passwd

    # Generate keys with nss-wrapper to provide passwd entries
    LD_PRELOAD="libnss_wrapper.so" NSS_WRAPPER_PASSWD="/tmp/passwd" NSS_WRAPPER_GROUP="/tmp/group" \
      ssh-keygen -t rsa -b 4096 -f "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" -N ""
    LD_PRELOAD="libnss_wrapper.so" NSS_WRAPPER_PASSWD="/tmp/passwd" NSS_WRAPPER_GROUP="/tmp/group" \
      ssh-keygen -t ecdsa -f "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" -N ""
    LD_PRELOAD="libnss_wrapper.so" NSS_WRAPPER_PASSWD="/tmp/passwd" NSS_WRAPPER_GROUP="/tmp/group" \
      ssh-keygen -t ed25519 -f "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" -N ""

    # Clean up temporary files
    rm -f /tmp/passwd /tmp/group
  fi

  # Set proper permissions for host keys
  chmod 600 "$SSH_HOST_KEYS_DIR"/ssh_host_*_key
  chmod 644 "$SSH_HOST_KEYS_DIR"/ssh_host_*_key.pub

  # Write dynamic config that gets included by sshd_config
  cat >/tmp/ssh_dynamic.conf <<-EOF
	# Hostkeys
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_rsa_key
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key
	HostKey $SSH_HOST_KEYS_DIR/ssh_host_ed25519_key

	Match User borgwarehouse
	  AuthorizedKeysFile $AUTHORIZED_KEYS_FILE
EOF
}

check_ssh_mount_permissions() {
  # Check if SSH mount directory has correct permissions (700)
  local current_perms=$(stat -c "%a" "$SSH_MOUNT_DIR" 2>/dev/null || echo "000")
  
  print_green "Checking SSH mount directory permissions: $SSH_MOUNT_DIR (current: $current_perms)"
  
  if [ "$current_perms" != "700" ]; then
    print_red "SSH mount directory has incorrect permissions: $current_perms (expected: 700)"
    print_green "Attempting to fix permissions..."
    
    if chmod 700 "$SSH_MOUNT_DIR" 2>/dev/null; then
      print_green "Successfully set permissions to 700 on $SSH_MOUNT_DIR"
    else
      print_red "ERROR: Cannot set permissions on SSH mount directory!"
      print_red "Please run the following command on the host system:"
      print_red "  sudo chmod 700 $SSH_MOUNT_DIR"
      print_red "  sudo chown \$(id -u):\$(id -g) $SSH_MOUNT_DIR"
      print_red ""
      print_red "The SSH mount directory must have 700 permissions and be owned by the user running the container."
      exit 1
    fi
  else
    print_green "SSH mount directory permissions are correct (700)"
  fi
}

check_ssh_directory() {
  if [ ! -d "$SSH_MOUNT_DIR" ]; then
    print_red "The $SSH_MOUNT_DIR directory does not exist, you need to mount it as docker volume."
    exit 1
  else
    check_ssh_mount_permissions
    
    mkdir -p "$SSH_CLIENT_DIR"
    chmod 700 "$SSH_CLIENT_DIR"
  fi
}

create_authorized_keys_file() {
  if [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
    print_green "The authorized_keys file does not exist, creating..."
    touch "$AUTHORIZED_KEYS_FILE"
  fi
  chmod 600 "$AUTHORIZED_KEYS_FILE"
}

check_repos_directory() {
  if [ ! -d "$REPOS_DIR" ]; then
    print_red "The repos directory does not exist, you need to mount it as docker volume."
    exit 2
  else 
    chmod 700 "$REPOS_DIR"
  fi
}

get_SSH_fingerprints() {
  print_green "Getting SSH fingerprints..."
  RSA_FINGERPRINT=$(ssh-keygen -lf "$SSH_HOST_KEYS_DIR/ssh_host_rsa_key" | awk '{print $2}')
  ED25519_FINGERPRINT=$(ssh-keygen -lf "$SSH_HOST_KEYS_DIR/ssh_host_ed25519_key" | awk '{print $2}')
  ECDSA_FINGERPRINT=$(ssh-keygen -lf "$SSH_HOST_KEYS_DIR/ssh_host_ecdsa_key" | awk '{print $2}')
  export SSH_SERVER_FINGERPRINT_RSA="$RSA_FINGERPRINT"
  export SSH_SERVER_FINGERPRINT_ED25519="$ED25519_FINGERPRINT"
  export SSH_SERVER_FINGERPRINT_ECDSA="$ECDSA_FINGERPRINT"
}

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

check_env
init_ssh_server
check_ssh_directory
create_authorized_keys_file
check_repos_directory
get_SSH_fingerprints

print_green "Successful initialization. BorgWarehouse is ready !"
exec supervisord -c /app/supervisord.conf
