#!/bin/bash
# Test helper: start an extra Catalog.API instance from the published binary as the eshop user,
# loading the same /etc/eshop env files as the lifecycle `run` script, then applying overrides.
#   usage: launch_catalog_instance.sh <port> [KEY=VALUE ...]
# A KEY given as "-KEY" (leading dash) is unset after the env files are loaded.
# Run through: sudo -n -u eshop env HOME=/var/lib/eshop bash launch_catalog_instance.sh ...
set -e
port="$1"; shift
for f in /etc/eshop/common.env /etc/eshop/catalog-api.env; do
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
    export "$k=$v"
  done < "$f"
done
export ASPNETCORE_URLS="http://127.0.0.1:${port}"
for kv in "$@"; do
  case "$kv" in
    -*) unset "${kv#-}" ;;
    *) export "$kv" ;;
  esac
done
cd /opt/eshop/catalog-api
exec /usr/bin/dotnet /opt/eshop/catalog-api/Catalog.API.dll $ESHOP_CONFIG_ARGS --urls "http://127.0.0.1:${port}"
