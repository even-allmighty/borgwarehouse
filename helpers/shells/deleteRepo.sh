#!/usr/bin/env bash

### DEPRECATED ### NodeJS will handle this in the future.

# Shell created by Raven for BorgWarehouse.
# This shell takes 1 arg : [repositoryName] with 8 char. length only.
# This shell **delete the repository** in arg and **all his data** and the line associated in the authorized_keys file.

# Exit when any command fails
set -e

# Load .env if exists
if [[ -f .env ]]; then
    source .env
fi

# Priority order: Docker variables > .env home variable > default
# Use Docker variables if available, otherwise fall back to home variable, then default
if [[ -n "$REPOS_DIR" && -n "$AUTHORIZED_KEYS_FILE" ]]; then
    # Docker environment - use Docker variables
    pool="$REPOS_DIR"
    authorized_keys="$AUTHORIZED_KEYS_FILE"
else
    # Non-Docker environment - use home variable with default fallback
    : "${home:=/home/borgwarehouse}"
    pool="${home}/repos"
    authorized_keys="${home}/.ssh/authorized_keys"
fi

# Check arg
if [[ $# -ne 1 || $1 = "" ]]; then
    echo -n "You must provide a repositoryName in argument." >&2
    exit 1
fi

# Check if the repositoryName pattern is an hexa 8 char. With createRepo.sh our randoms are hexa of 8 characters.
# If we receive another pattern there is necessarily a problem.
repositoryName=$1
if ! [[ "$repositoryName" =~ ^[a-f0-9]{8}$ ]]; then
  echo "Invalid repository name. Must be an 8-character hex string." >&2
  exit 2
fi

# Delete the repository and the line associated in the authorized_keys file
if [ -d "${pool}/${repositoryName}" ]; then
        # Delete the repository
        rm -rf """${pool}""/""${repositoryName:?}"""
        # Delete the line in the authorized_keys file
        sed -i "/${repositoryName}/d" "${authorized_keys}"
        echo -n "The folder ""${pool}"/"${repositoryName}"" and all its data have been deleted. The line associated in the authorized_keys file has been deleted."
else
        # Delete the line in the authorized_keys file
        sed -i "/${repositoryName}/d" "${authorized_keys}"
        echo -n "The folder ""${pool}"/"${repositoryName}"" did not exist (repository never initialized or used). The line associated in the authorized_keys file has been deleted."
fi