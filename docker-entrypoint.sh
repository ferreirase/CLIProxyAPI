#!/bin/sh
# Bind-mounting a single file (config.yaml) is fragile: if the host source
# doesn't exist yet, Docker creates a directory there instead, and the app
# fails with "read config.yaml: is a directory". To avoid that, compose
# mounts a directory (config-data/) and this entrypoint ensures the actual
# config.yaml lives inside it, then symlinks it to the path the app expects.
set -eu

CONFIG_DIR="/CLIProxyAPI/config-data"
CONFIG_FILE="/CLIProxyAPI/config.yaml"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
  cp /CLIProxyAPI/config.example.yaml "$CONFIG_DIR/config.yaml"
fi

if [ -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
  rm -rf "$CONFIG_FILE"
fi
ln -sf "$CONFIG_DIR/config.yaml" "$CONFIG_FILE"

exec "$@"
