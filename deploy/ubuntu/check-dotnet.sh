#!/usr/bin/env bash
# check-dotnet.sh - ".NET toolchain consistency check".
# Exits non-zero unless an installed SDK satisfies the repository's global.json
# (sdk.version honouring rollForward / allowPrerelease). Needs no root.
#
# Usage: deploy/ubuntu/check-dotnet.sh [path/to/global.json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/steps-dotnet.sh
source "${SCRIPT_DIR}/lib/steps-dotnet.sh"

main() {
    case "${1:-}" in
        -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
    local gj=${1:-${ESHOP_GLOBAL_JSON}}

    if ! dotnet_host_path >/dev/null; then
        log_error "dotnet is not installed (global.json requires SDK $(global_json_sdk_version "${gj}")); run provision-host.sh"
        exit 1
    fi

    # 1) our reading of global.json against `dotnet --list-sdks`
    dotnet_check_global_json "${gj}" || exit 1

    # 2) the SDK resolver itself, run in the directory that holds global.json: this is
    #    exactly what `dotnet build` / `dotnet publish` will do.
    local dir host resolved
    dir="$(dirname "${gj}")"
    host="$(dotnet_host_path)"
    if ! resolved="$(cd "${dir}" && "${host}" --version 2>&1)"; then
        log_error "dotnet SDK resolution failed in ${dir}: ${resolved}"
        exit 1
    fi
    log_ok "dotnet resolves SDK ${resolved} for ${dir}"
}

main "$@"
