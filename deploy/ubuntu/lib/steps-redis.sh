#!/usr/bin/env bash
# steps-redis.sh - distro Redis (7.0.x from Ubuntu 24.04, BSD-3; no third-party repo):
# loopback only + requirepass. Configuration lives in a separate managed file that
# is pulled in with a single `include` line at the END of redis.conf (later
# directives win), so package upgrades of redis.conf do not erase it.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=steps-secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/steps-secrets.sh"

ESHOP_REDIS_CONF="${ESHOP_REDIS_CONF:-/etc/redis/redis.conf}"
ESHOP_REDIS_EXTRA_CONF="${ESHOP_REDIS_EXTRA_CONF:-/etc/redis/eshop.conf}"
ESHOP_REDIS_SERVICE="${ESHOP_REDIS_SERVICE:-redis-server}"

# redis_cli_auth ARGS... - redis-cli authenticated through REDISCLI_AUTH (keeps the password out of argv).
redis_cli_auth() {
    REDISCLI_AUTH="${REDIS_PASSWORD}" redis-cli -h "${ESHOP_LOOPBACK_ADDR}" -p "${ESHOP_REDIS_PORT}" --no-auth-warning "$@"
}

redis_ping_auth() { [[ "$(redis_cli_auth ping 2>/dev/null)" == "PONG" ]]; }

step_redis() {
    log_step "Redis (loopback, requirepass)"
    require_cmd redis-cli
    load_secrets
    [[ -f "${ESHOP_REDIS_CONF}" ]] || die "Redis config not found: ${ESHOP_REDIS_CONF} (is redis-server installed?)"

    local changed=0 redis_group=root
    getent group redis >/dev/null && redis_group=redis

    if write_file_if_changed "${ESHOP_REDIS_EXTRA_CONF}" 0640 "root:${redis_group}" <<CONF
# Managed by eshop provision-host.sh - re-generated from /etc/eshop/secrets.env.
bind ${ESHOP_LOOPBACK_ADDR}
port ${ESHOP_REDIS_PORT}
protected-mode yes
requirepass ${REDIS_PASSWORD}
CONF
    then
        changed=1
    fi

    local include_line="include ${ESHOP_REDIS_EXTRA_CONF}"
    if ! grep -qxF "${include_line}" "${ESHOP_REDIS_CONF}"; then
        ensure_line "${ESHOP_REDIS_CONF}" "${include_line}"
        changed=1
    fi

    if [[ "${changed}" -eq 1 ]]; then
        log_info "Redis configuration changed: restarting ${ESHOP_REDIS_SERVICE}"
        svc_restart "${ESHOP_REDIS_SERVICE}"
    elif ! redis_ping_auth; then
        log_info "Redis is not answering authenticated pings: starting ${ESHOP_REDIS_SERVICE}"
        svc_start "${ESHOP_REDIS_SERVICE}"
    else
        log_ok "Redis configuration unchanged; no restart"
    fi

    if ! wait_until 30 "Redis to answer authenticated PING" redis_ping_auth; then
        fail_or_warn "Redis does not answer PING with the secrets.env password"
        return 0
    fi
    if [[ "$(REDISCLI_AUTH='' redis-cli -h "${ESHOP_LOOPBACK_ADDR}" -p "${ESHOP_REDIS_PORT}" ping 2>&1 || true)" == "PONG" ]]; then
        die "Redis answered an unauthenticated PING: requirepass is not in effect"
    fi
    assert_loopback_listener "${ESHOP_REDIS_PORT}" Redis || die "Redis is not restricted to loopback"
    log_ok "Redis answers PING with authentication, rejects anonymous access, loopback only"
}
