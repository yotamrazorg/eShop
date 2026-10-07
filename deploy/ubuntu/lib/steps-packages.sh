#!/usr/bin/env bash
# steps-packages.sh - apt packages for the native stack (distro packages only,
# no third-party repositories: PostgreSQL 16, Redis 7.0.x, RabbitMQ 3.12.x).
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Helper tooling used by the scripts: curl/ca-certificates (health checks, dotnet-install.sh),
# gettext-base (envsubst), iproute2 (ss, loopback checks in verify.sh).
ESHOP_PKGS_BASE=(curl ca-certificates gettext-base iproute2)
ESHOP_PKGS_POSTGRES=(postgresql-16 postgresql-16-pgvector)
ESHOP_PKGS_REDIS=(redis-server)
ESHOP_PKGS_RABBITMQ=(rabbitmq-server)

# warn_if_unsupported_os - the milestone targets Ubuntu 24.04 (noble).
warn_if_unsupported_os() {
    local id='' ver=''
    if [[ -r /etc/os-release ]]; then
        id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        ver="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    fi
    if [[ "${id}" != "ubuntu" || "${ver}" != "24.04" ]]; then
        log_warn "this host is '${id:-unknown} ${ver:-unknown}', the supported target is Ubuntu 24.04; package names/versions (postgresql-16, pgvector, .NET 10) may not be available"
    fi
}

step_packages() {
    log_step "apt packages"
    require_cmd apt-get dpkg-query
    warn_if_unsupported_os
    apt_install "${ESHOP_PKGS_BASE[@]}"
    apt_install "${ESHOP_PKGS_POSTGRES[@]}" "${ESHOP_PKGS_REDIS[@]}" "${ESHOP_PKGS_RABBITMQ[@]}"
}
