#!/usr/bin/env bash
# steps-rabbitmq.sh - distro RabbitMQ (3.12.x): loopback only, dedicated vhost and
# user, `guest` removed.
#
# Loopback binding notes
#   * AMQP listener: NODE_IP_ADDRESS=127.0.0.1 in /etc/rabbitmq/rabbitmq-env.conf
#     (this file takes the variables WITHOUT the RABBITMQ_ prefix; it is the file
#     form of RABBITMQ_NODE_IP_ADDRESS).
#   * Erlang distribution (25672) is bound to loopback with inet_dist_use_interface.
#   * epmd (4369) is bound through ERL_EPMD_ADDRESS and, when the distro starts it via
#     socket activation, a systemd drop-in for epmd.socket.
#   * The management plugin is NOT enabled; if you enable it, set
#     management.tcp.ip = 127.0.0.1 in /etc/rabbitmq/conf.d/.
#   * guest: removed. (RabbitMQ already restricts guest to loopback by default;
#     deleting it removes the well-known credential altogether.)
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=steps-secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/steps-secrets.sh"

ESHOP_RABBITMQ_ENV_CONF="${ESHOP_RABBITMQ_ENV_CONF:-/etc/rabbitmq/rabbitmq-env.conf}"
ESHOP_RABBITMQ_SERVICE="${ESHOP_RABBITMQ_SERVICE:-rabbitmq-server}"
ESHOP_RABBITMQ_VHOST="${ESHOP_RABBITMQ_VHOST:-eshop}"
ESHOP_RABBITMQ_USER="${ESHOP_RABBITMQ_USER:-eshop}"
ESHOP_EPMD_DROPIN_DIR="${ESHOP_SYSTEMD_DIR}/epmd.socket.d"

rabbit_ready() { timeout 20 rabbitmqctl --quiet await_startup >/dev/null 2>&1; }

rabbit_list_vhosts() { rabbitmqctl --quiet --silent list_vhosts name 2>/dev/null; }
rabbit_list_users()  { rabbitmqctl --quiet --silent list_users 2>/dev/null | awk '{print $1}'; }

step_rabbitmq() {
    log_step "RabbitMQ (loopback, vhost ${ESHOP_RABBITMQ_VHOST}, no guest)"
    require_cmd rabbitmqctl
    load_secrets
    ensure_dir "$(dirname "${ESHOP_RABBITMQ_ENV_CONF}")" 0755 root:root

    # --- loopback binding ----------------------------------------------------------------
    [[ -e "${ESHOP_RABBITMQ_ENV_CONF}" ]] || : > "${ESHOP_RABBITMQ_ENV_CONF}"
    local before after restart_needed=0
    before="$(file_fingerprint "${ESHOP_RABBITMQ_ENV_CONF}")"
    ensure_kv "${ESHOP_RABBITMQ_ENV_CONF}" NODE_IP_ADDRESS "${ESHOP_LOOPBACK_ADDR}"
    ensure_kv "${ESHOP_RABBITMQ_ENV_CONF}" ERL_EPMD_ADDRESS "${ESHOP_LOOPBACK_ADDR}"
    ensure_kv "${ESHOP_RABBITMQ_ENV_CONF}" SERVER_ADDITIONAL_ERL_ARGS '"-kernel inet_dist_use_interface {127,0,0,1}"'
    after="$(file_fingerprint "${ESHOP_RABBITMQ_ENV_CONF}")"
    [[ "${before}" == "${after}" ]] || restart_needed=1

    # epmd socket activation (Debian/Ubuntu erlang-base): reset ListenStream to loopback.
    if have_systemd && systemctl list-unit-files epmd.socket >/dev/null 2>&1 \
        && systemctl list-unit-files epmd.socket 2>/dev/null | grep -q '^epmd\.socket'; then
        ensure_dir "${ESHOP_EPMD_DROPIN_DIR}" 0755 root:root
        if write_file_if_changed "${ESHOP_EPMD_DROPIN_DIR}/eshop-loopback.conf" 0644 root:root <<'CONF'
# Managed by eshop provision-host.sh: epmd (Erlang port mapper) on loopback only.
[Socket]
ListenStream=
ListenStream=127.0.0.1:4369
CONF
        then
            systemctl daemon-reload
            systemctl restart epmd.socket || log_warn "could not restart epmd.socket"
            restart_needed=1
        fi
    fi

    if [[ "${restart_needed}" -eq 1 ]]; then
        log_info "RabbitMQ binding configuration changed: restarting ${ESHOP_RABBITMQ_SERVICE}"
        svc_restart "${ESHOP_RABBITMQ_SERVICE}"
    elif ! rabbit_ready; then
        log_info "RabbitMQ is not running: starting ${ESHOP_RABBITMQ_SERVICE}"
        svc_start "${ESHOP_RABBITMQ_SERVICE}"
    else
        log_ok "RabbitMQ binding configuration unchanged; no restart"
    fi

    if ! wait_until 120 "RabbitMQ node to finish starting" rabbit_ready; then
        fail_or_warn "RabbitMQ did not start; vhost/user not configured"
        return 0
    fi

    # --- vhost, user, permissions -----------------------------------------------------------
    if rabbit_list_vhosts | grep -qx "${ESHOP_RABBITMQ_VHOST}"; then
        log_ok "vhost ${ESHOP_RABBITMQ_VHOST} exists"
    else
        rabbitmqctl --quiet add_vhost "${ESHOP_RABBITMQ_VHOST}" >/dev/null
        log_info "created vhost ${ESHOP_RABBITMQ_VHOST}"
    fi

    assert_alnum RABBITMQ_PASSWORD "${RABBITMQ_PASSWORD}"
    # Note: rabbitmqctl only accepts the password as an argument, so it is briefly
    # visible in the process list of this root-only provisioning run.
    if rabbit_list_users | grep -qx "${ESHOP_RABBITMQ_USER}"; then
        rabbitmqctl --quiet change_password "${ESHOP_RABBITMQ_USER}" "${RABBITMQ_PASSWORD}" >/dev/null
        log_info "re-applied password of RabbitMQ user ${ESHOP_RABBITMQ_USER} from secrets.env"
    else
        rabbitmqctl --quiet add_user "${ESHOP_RABBITMQ_USER}" "${RABBITMQ_PASSWORD}" >/dev/null
        log_info "created RabbitMQ user ${ESHOP_RABBITMQ_USER}"
    fi
    rabbitmqctl --quiet set_user_tags "${ESHOP_RABBITMQ_USER}" >/dev/null      # no tags: not an administrator
    rabbitmqctl --quiet set_permissions -p "${ESHOP_RABBITMQ_VHOST}" "${ESHOP_RABBITMQ_USER}" ".*" ".*" ".*" >/dev/null
    log_ok "user ${ESHOP_RABBITMQ_USER} has full permissions on vhost ${ESHOP_RABBITMQ_VHOST}"

    if rabbit_list_users | grep -qx guest; then
        rabbitmqctl --quiet delete_user guest >/dev/null
        log_info "deleted the default guest user"
    else
        log_ok "guest user already absent"
    fi

    assert_loopback_listener "${ESHOP_AMQP_PORT}" RabbitMQ || die "RabbitMQ AMQP listener is not restricted to loopback"
}
