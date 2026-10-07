#!/usr/bin/env bash
# steps-host.sh - eshop system user and directory layout.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# step_host - create the unprivileged `eshop` system account and the layout:
#   /opt/eshop        root:root   0755  published binaries (read-only for services)
#   /etc/eshop        root:eshop  0750  secrets + env files
#   /var/lib/eshop    eshop:eshop 0750  service state (DataProtection keys, later: Identity signing key)
step_host() {
    log_step "Host user and directory layout"

    if getent group "${ESHOP_GROUP}" >/dev/null; then
        log_ok "group ${ESHOP_GROUP} exists"
    else
        groupadd --system "${ESHOP_GROUP}"
        log_info "created system group ${ESHOP_GROUP}"
    fi

    if id -u "${ESHOP_USER}" >/dev/null 2>&1; then
        log_ok "user ${ESHOP_USER} exists"
    else
        # --no-create-home: /var/lib/eshop is created below with strict permissions.
        useradd --system --gid "${ESHOP_GROUP}" --home-dir "${ESHOP_STATE_DIR}" --no-create-home \
            --shell /usr/sbin/nologin --comment "eShop service account" "${ESHOP_USER}"
        log_info "created system user ${ESHOP_USER} (nologin)"
    fi

    # An existing account created by hand must not be able to log in interactively.
    local shell
    shell="$(getent passwd "${ESHOP_USER}" | cut -d: -f7)"
    if [[ "${shell}" != "/usr/sbin/nologin" && "${shell}" != "/sbin/nologin" && "${shell}" != "/bin/false" ]]; then
        usermod --shell /usr/sbin/nologin "${ESHOP_USER}"
        log_warn "set login shell of ${ESHOP_USER} to /usr/sbin/nologin (was ${shell})"
    fi

    ensure_dir "${ESHOP_OPT_DIR}"   0755 root:root
    ensure_dir "${ESHOP_ETC_DIR}"   0750 "root:${ESHOP_GROUP}"
    ensure_dir "${ESHOP_STATE_DIR}" 0750 "${ESHOP_USER}:${ESHOP_GROUP}"
}
