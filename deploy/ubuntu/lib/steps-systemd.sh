#!/usr/bin/env bash
# steps-systemd.sh - install eshop.target and the unit of every wired service.
#
# For each wired service (lib/services.sh) the unit comes from
#   systemd/eshop-<name>.service            (explicit file, wins), else
#   systemd/eshop-service.service.tmpl      (generic template, @NAME@/@ASSEMBLY@/... tokens)
# Units are installed to /etc/systemd/system, the manager is reloaded when anything
# changed, and the units are ENABLED but not started (nothing is published yet at
# provisioning time; see publish.sh). Without a running systemd (containers) every
# systemctl call degrades to a warning.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=services.sh
source "$(dirname "${BASH_SOURCE[0]}")/services.sh"

ESHOP_SYSTEMD_SRC_DIR="${ESHOP_SYSTEMD_SRC_DIR:-${ESHOP_DEPLOY_DIR}/systemd}"
ESHOP_UNIT_TEMPLATE="${ESHOP_UNIT_TEMPLATE:-${ESHOP_SYSTEMD_SRC_DIR}/eshop-service.service.tmpl}"

# unit_body_from FILE - FILE without its leading comment header (up to and
# including the first blank line), i.e. exactly the unit text.
unit_body_from() {
    awk 'seen { print; next } /^$/ { seen = 1 }' "$1"
}

# render_unit_template NAME - the generic unit rendered for service NAME (stdout).
render_unit_template() {
    local name=$1 tmp
    tmp="$(mktemp)"
    unit_body_from "${ESHOP_UNIT_TEMPLATE}" > "${tmp}"
    render_at_template "${tmp}" \
        "NAME=${name}" \
        "ASSEMBLY=$(service_assembly "${name}")" \
        "USER=$(service_user "${name}")" \
        "GROUP=${ESHOP_GROUP}" \
        "LOOPBACK=${ESHOP_LOOPBACK_ADDR}" \
        "PG_PORT=${ESHOP_PG_PORT}" \
        "AMQP_PORT=${ESHOP_AMQP_PORT}"
    rm -f "${tmp}"
}

# unit_source_for NAME - "explicit:<path>" or "template".
unit_source_for() {
    local f
    f="${ESHOP_SYSTEMD_SRC_DIR}/$(service_unit "$1")"
    if [[ -f "${f}" ]]; then printf 'explicit:%s\n' "${f}"; else printf 'template\n'; fi
}

step_systemd() {
    log_step "systemd units"
    local changed=0 name src unit
    local -a units=()

    if install_file_if_changed "${ESHOP_SYSTEMD_SRC_DIR}/eshop.target" "${ESHOP_SYSTEMD_DIR}/eshop.target" 0644 root:root; then
        changed=1
    fi

    while IFS= read -r name; do
        unit="$(service_unit "${name}")"
        src="$(unit_source_for "${name}")"
        if [[ "${src}" == explicit:* ]]; then
            if install_file_if_changed "${src#explicit:}" "${ESHOP_SYSTEMD_DIR}/${unit}" 0644 root:root; then changed=1; fi
        else
            [[ -f "${ESHOP_UNIT_TEMPLATE}" ]] || die "no unit file or template for ${name}"
            local body
            body="$(render_unit_template "${name}")"
            if printf '%s\n' "${body}" | write_file_if_changed "${ESHOP_SYSTEMD_DIR}/${unit}" 0644 root:root; then changed=1; fi
        fi
        units+=("${unit}")
    done < <(list_wired_services)

    if [[ "${changed}" -eq 1 ]]; then
        sd_daemon_reload
    else
        log_ok "unit files unchanged"
    fi

    # Verify what was installed (informational: the binaries do not exist before publish).
    if have_systemd && command_exists systemd-analyze; then
        if ! systemd-analyze verify "${ESHOP_SYSTEMD_DIR}/eshop.target" "${units[@]/#/${ESHOP_SYSTEMD_DIR}/}" 2>&1 | sed 's/^/        /' >&2; then
            log_warn "systemd-analyze verify reported problems (see above)"
        fi
    fi

    sd_enable eshop.target "${units[@]}"
    log_ok "enabled: eshop.target ${units[*]} (start them after publish.sh)"
}
