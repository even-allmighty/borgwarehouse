#!/usr/bin/env bash

### DEPRECATED ### NodeJS will handle this in the future.

# Shell created by Raven for BorgWarehouse.
# Get the size of all repositories in a JSON output.
# stdout will be an array like :
# [
#     { size: 32, name: '10e73223' },
#     { size: 1155672, name: '83bd4ef1' },
#     { size: 112, name: '635a6f8b' },
#     { size: 32, name: 'bce68e87' },
#     { size: 44, name: 'e4c04552' },
# ];

# Exit when any command fails
set -e

# Ignore "lost+found" directories
GLOBIGNORE="LOST+FOUND:lost+found"

# Load .env if exists
if [[ -f .env ]]; then
    source .env
fi

# Priority order: Docker variables > .env home variable > default
# Use Docker variables if available, otherwise fall back to home variable, then default
if [[ -n "$REPOS_DIR" ]]; then
    # Docker environment - use Docker variables
    repos_path="$REPOS_DIR"
else
    # Non-Docker environment - use home variable with default fallback
    : "${home:=/home/borgwarehouse}"
    repos_path="${home}/repos"
fi

# Get the size of each repository and format as JSON
cd "$repos_path"
output=$(du -s -L -- * 2>/dev/null | awk '{print "{\"size\":" $1 ",\"name\":\"" $2 "\"}"}' | jq -s '.')
if [ -z "$output" ]; then
  output="[]"
fi

# Print the JSON output
echo "$output"
