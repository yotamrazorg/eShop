#!/usr/bin/env bash
# publish.sh - framework-dependent `dotnet publish -c Release` of eShop services into
# /opt/eshop/<service>.
#
# Usage: sudo deploy/ubuntu/publish.sh [service|all] [--no-restart]
#   service   a name from lib/services.sh (e.g. catalog-api); `all` (default) = every wired service
#
# Table driven: nothing here is specific to Catalog.API. Only services with
# wired=yes in lib/services.sh can be published in this milestone (catalog-api).
#
# Safe to re-run. The new build is staged next to the target and swapped in with
# renames, ownership is root:eshop with group read access, and the systemd unit is
# restarted only if it is currently active. The SDK is checked against global.json first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"
# shellcheck source=lib/steps-dotnet.sh
source "${SCRIPT_DIR}/lib/steps-dotnet.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [service|all] [--no-restart]

Publish a service (framework-dependent, Release) into ${ESHOP_OPT_DIR}/<service>.

Services:
$(while IFS= read -r n; do
    if service_wired "${n}"; then printf '  %-18s port %-5s (wired)\n' "${n}" "$(service_port "${n}")"; else printf '  %-18s port %-5s (not wired yet)\n' "${n}" "$(service_port "${n}")"; fi
done < <(list_services))
USAGE
}

# publish_service NAME RESTART(1|0)
publish_service() {
    local name=$1 restart=$2
    local project assembly dest staging old pubdir
    local -a req
    project="${ESHOP_REPO_DIR}/$(service_project "${name}")"
    assembly="$(service_assembly "${name}")"
    dest="$(service_install_dir "${name}")"
    staging="${dest}.staging"
    old="${dest}.old"
    [[ -d "${project}" ]] || die "project directory not found for ${name}: ${project}"

    log_step "Publishing ${name} (${project#"${ESHOP_REPO_DIR}"/}) -> ${dest}"

    # Leftovers of an interrupted earlier run.
    rm -rf "${staging}" "${old}"

    # Build as the invoking (non-root) user when started through sudo, so the
    # repository's obj/ and artifacts/ directories do not end up owned by root.
    local build_user=root build_home=${HOME:-/root}
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
        build_user="${SUDO_USER}"
        build_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi
    pubdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${pubdir}' '${staging}'" RETURN
    chown "${build_user}" "${pubdir}"

    log_info "dotnet publish as ${build_user}"
    runuser -u "${build_user}" -- env \
        HOME="${build_home}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        "$(dotnet_host_path)" publish "${project}" \
        -c Release --no-self-contained -p:UseAppHost=false \
        -o "${pubdir}"

    [[ -f "${pubdir}/${assembly}.dll" ]] || die "publish did not produce ${assembly}.dll"
    local rp
    IFS=',' read -r -a req <<<"$(service_required_paths "${name}")"
    for rp in "${req[@]}"; do
        [[ -z "${rp}" ]] && continue
        [[ -e "${pubdir}/${rp}" ]] || die "publish output of ${name} is missing required content: ${rp}"
    done

    # Stage with final ownership/permissions, then swap in.
    ensure_dir "${ESHOP_OPT_DIR}" 0755 root:root
    mkdir -p "${staging}"
    cp -a "${pubdir}/." "${staging}/"
    chown -R "root:${ESHOP_GROUP}" "${staging}"
    chmod -R u=rwX,g=rX,o= "${staging}"
    chmod 0750 "${staging}"

    [[ ! -e "${dest}" ]] || mv -T "${dest}" "${old}"
    mv -T "${staging}" "${dest}"
    rm -rf "${old}"
    log_ok "published ${name} to ${dest}"

    local unit
    unit="$(service_unit "${name}")"
    if [[ "${restart}" -eq 1 ]]; then
        if sd_is_active "${unit}"; then
            log_info "restarting ${unit}"
            svc_restart "${unit}"
        else
            log_info "${unit} is not active; start it with: systemctl start ${unit}"
        fi
    fi
}

main() {
    local target='' restart=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --no-restart) restart=0; shift ;;
            -*) usage >&2; die "unknown option: $1" ;;
            *) [[ -z "${target}" ]] || die "only one service (or 'all') may be given"; target=$1; shift ;;
        esac
    done
    target=${target:-all}

    assert_service_table

    local -a names=()
    if [[ "${target}" == "all" ]]; then
        mapfile -t names < <(list_wired_services)
    else
        service_exists "${target}" || { usage >&2; die "unknown service: ${target} (known: $(list_services | tr '\n' ' '))"; }
        service_wired "${target}" || die "service ${target} is not wired yet (wired=no in deploy/ubuntu/lib/services.sh)"
        names=("${target}")
    fi
    [[ "${#names[@]}" -gt 0 ]] || die "no wired services to publish"

    require_root

    id -u "${ESHOP_USER}" >/dev/null 2>&1 || die "user ${ESHOP_USER} does not exist; run provision-host.sh first"

    log_step ".NET toolchain check"
    dotnet_check_global_json || die "install a matching SDK first (provision-host.sh or check-dotnet.sh for details)"

    local n
    for n in "${names[@]}"; do
        publish_service "${n}" "${restart}"
    done
}

main "$@"
