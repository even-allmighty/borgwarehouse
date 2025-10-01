#!/usr/bin/env bash

### DEPRECATED ### NodeJS will handle this in the future.

# Shell created by Raven for BorgWarehouse.
# Get the timestamp of the last modification of the file integrity.* for of all repositories in a JSON output.
# stdout will be an array like :
# [
#   {
#     "repositoryName": "a7035047",
#     "lastSave": 1691341603
#   },
#   {
#     "repositoryName": "a7035048",
#     "lastSave": 1691342688
#   }
# ]


# Exit when any command fails
set -e

# Load BorgWarehouse configuration
source "$(dirname "$0")/bw-config"

# Use centralized configuration
repos_path="$BW_REPOS_DIR"

if [ -n "$(find -L "$repos_path" -mindepth 1 -maxdepth 1 -type d)" ]; then
  stat --format='{"repositoryName":"%n","lastSave":%Y}' \
  "$repos_path"/*/integrity* | 
  jq --slurp '[.[] | .repositoryName = (.repositoryName | split("/")[-2])]'
else
    echo "[]"
fi