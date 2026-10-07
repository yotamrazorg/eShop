#!/usr/bin/env bash
# provision-host.sh - provision a bare Ubuntu 24.04 host for the native eShop stack.
#
# One orchestrator that runs small idempotent step functions from lib/steps-*.sh:
#   host      eshop system user, /opt/eshop, /etc/eshop, /var/lib/eshop
#   secrets   generate-once secrets in /etc/eshop/secrets.env (0600 root:root)
#   packages  apt: postgresql-16, postgresql-16-pgvector, redis-server, rabbitmq-server, helpers
#   dotnet    .NET SDK/runtime consistent with global.json (apt, else dotnet-install.sh)
#   postgres  loopback + scram, role, databases, pgvector
#   redis     loopback + requirepass
#   rabbitmq  loopback, vhost + user, guest removed
#   env       render env/*.env.tmpl -> /etc/eshop/*.env (0640 root:eshop)
#   systemd   install + enable eshop.target and the wired units
#
# Re-running is safe: each step checks the current state first, secrets are never
# regenerated, and services are only restarted when their configuration changed.
# No Docker/Podman is installed or used.
#
# Usage: sudo deploy/ubuntu/provision-host.sh [--skip STEP]... [--only STEP]... [--list-steps] [-h]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"
for _lib in host secrets packages dotnet postgres redis rabbitmq env systemd; do
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/steps-${_lib}.sh"
done
unset _lib

ALL_STEPS=(host secrets packages dotnet postgres redis rabbitmq env systemd)

usage() {
    cat <<USAGE
Usage: sudo $0 [options]

Provision this host for the native eShop stack (idempotent; safe to re-run).

Options:
  --skip STEP     skip a step (repeatable)
  --only STEP     run only the given step(s) (repeatable)
  --list-steps    print the step names in execution order
  -h, --help      show this help

Steps: ${ALL_STEPS[*]}
USAGE
}

contains() {
    local needle=$1; shift
    local x
    for x in "$@"; do [[ "${x}" == "${needle}" ]] && return 0; done
    return 1
}

main() {
    local -a skip=() only=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip) [[ $# -ge 2 ]] || die "--skip needs a step name"; skip+=("$2"); shift 2 ;;
            --only) [[ $# -ge 2 ]] || die "--only needs a step name"; only+=("$2"); shift 2 ;;
            --list-steps) printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done

    local s
    for s in "${skip[@]}" "${only[@]}"; do
        contains "${s}" "${ALL_STEPS[@]}" || die "unknown step: ${s} (valid: ${ALL_STEPS[*]})"
    done

    require_root
    assert_service_table
    if ! have_systemd; then
        log_warn "systemd is not running here (container/chroot): service management steps will be skipped or degraded with warnings"
    fi

    for s in "${ALL_STEPS[@]}"; do
        if [[ "${#only[@]}" -gt 0 ]] && ! contains "${s}" "${only[@]}"; then continue; fi
        if [[ "${#skip[@]}" -gt 0 ]] && contains "${s}" "${skip[@]}"; then
            log_warn "skipping step ${s}"
            continue
        fi
        "step_${s}"
    done

    log_step "Provisioning complete"
    log_info "next: sudo ${SCRIPT_DIR}/publish.sh catalog-api && sudo systemctl start eshop-catalog-api (or eshop.target) && ${SCRIPT_DIR}/verify.sh"
}

main "$@"
