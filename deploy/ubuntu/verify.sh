#!/usr/bin/env bash
# verify.sh - minimal post-deployment verification for the native eShop stack.
#
# Checks (each prints PASS/FAIL, a summary follows, exit status is non-zero on any FAIL):
#   a) systemd units of all wired services (and the distro services they need) are active
#   b) GET /health and GET /api/catalog/items?api-version=1.0 on catalog-api: JSON with items (count > 0)
#   c) the `vector` extension is installed in catalogdb
#   d) no container runtime is required: no eshop unit depends on docker/podman/containerd
#      (a container runtime merely being installed is reported, never a failure)
#   e) hardening spot checks: Postgres/Redis/RabbitMQ and the services listen on loopback only,
#      secrets/env file permissions
#
# Usage: deploy/ubuntu/verify.sh [--wait SECONDS]     (needs root or passwordless sudo for check c)
#   --wait N   keep retrying the HTTP checks for up to N seconds (default 60) to ride out
#              the EF migrations + seeding that run at the first service start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"

PASS=0
FAIL=0
FAILED_CHECKS=()
WAIT_SECONDS=60

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$*"); printf '  FAIL  %s\n' "$*"; }
note() { printf '  info  %s\n' "$*"; }

# check DESCRIPTION CMD... - PASS if CMD succeeds.
check() {
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi
}

section() { printf '\n%s\n' "$*"; }

# retry_for SECONDS CMD... - run CMD until it succeeds or the time is up.
retry_for() {
    local secs=$1; shift
    local i
    for ((i = 0; i <= secs; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        [[ "${i}" -lt "${secs}" ]] && sleep 1
    done
    return 1
}

curl_ok() { curl -fsS --max-time 10 "$@"; }

# JSON helpers without jq: the Catalog response is {"pageIndex":..,"pageSize":..,"count":N,"data":[{...}]}
json_count_gt0() {
    local body=$1 n
    n="$(grep -oE '"count"[[:space:]]*:[[:space:]]*[0-9]+' <<<"${body}" | head -n1 | grep -oE '[0-9]+$' || true)"
    [[ -n "${n}" && "${n}" -gt 0 ]] && grep -qE '"data"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' <<<"${body}"
}

# ---------------------------------------------------------------------------
check_units() {
    section "a) systemd units"
    if ! have_systemd; then
        fail "systemd is not running on this host; cannot check units"
        return
    fi
    local n u
    for u in postgresql redis-server rabbitmq-server; do
        check "${u}.service is active" systemctl is-active --quiet "${u}.service"
    done
    while IFS= read -r n; do
        u="$(service_unit "${n}")"
        check "${u} is active" systemctl is-active --quiet "${u}"
    done < <(list_wired_services)
}

catalog_items_ok() {
    local base=$1 body
    body="$(curl_ok "${base}/api/catalog/items?api-version=1.0")" || return 1
    json_count_gt0 "${body}"
}

check_catalog_http() {
    section "b) catalog-api HTTP"
    local port base
    port="$(service_port catalog-api)"
    base="${ESHOP_VERIFY_BASE_URL:-http://127.0.0.1:${port}}"

    if retry_for "${WAIT_SECONDS}" curl_ok "${base}/health"; then
        pass "GET ${base}/health -> $(curl_ok "${base}/health" 2>/dev/null | head -c 40)"
    else
        fail "GET ${base}/health did not return 2xx within ${WAIT_SECONDS}s (is ESHOP_EXPOSE_HEALTH_ENDPOINTS=true and the unit started?)"
    fi

    if retry_for "${WAIT_SECONDS}" catalog_items_ok "${base}"; then
        pass "GET /api/catalog/items?api-version=1.0 returned JSON with count > 0 (seeded)"
    else
        fail "GET /api/catalog/items?api-version=1.0 did not return JSON with items (count > 0)"
    fi
}

vector_present() {
    [[ "$(as_postgres psql -X -q -tA -d catalogdb -c "SELECT extname FROM pg_extension WHERE extname = 'vector'" 2>/dev/null)" == "vector" ]]
}

check_vector() {
    section "c) pgvector"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! sudo -n true >/dev/null 2>&1; then
        fail "cannot query PostgreSQL as the postgres user (run as root or with passwordless sudo)"
        return
    fi
    if vector_present; then
        pass "extension 'vector' is installed in catalogdb"
    else
        fail "extension 'vector' is NOT installed in catalogdb"
    fi
}

check_no_container_runtime() {
    section "d) no container runtime required"
    local rt found=0
    for rt in docker podman containerd; do
        if command_exists "${rt}"; then
            found=1
            note "${rt} is installed on this host; that is fine as long as nothing in the stack uses it"
        fi
    done
    [[ "${found}" -eq 1 ]] || pass "no container runtime (docker/podman/containerd) installed"

    if ! have_systemd; then
        note "systemd not running: skipped unit dependency inspection"
        return
    fi
    local deps
    deps="$(systemctl list-dependencies --all eshop.target 2>/dev/null || true)"
    if grep -Eiq 'docker|podman|containerd' <<<"${deps}"; then
        fail "eshop.target dependency tree references a container runtime"
    else
        pass "eshop.target dependency tree has no docker/podman/containerd units"
    fi
    local n u props
    while IFS= read -r n; do
        u="$(service_unit "${n}")"
        props="$(systemctl show -p Requires -p Wants -p BindsTo -p After -p Before "${u}" 2>/dev/null || true)"
        if grep -Eiq 'docker|podman|containerd' <<<"${props}"; then
            fail "${u} is ordered/dependent on a container runtime unit"
        else
            pass "${u} has no container runtime dependency"
        fi
    done < <(list_wired_services)
}

file_mode_owner() { stat -c '%a %U:%G' "$1" 2>/dev/null; }

check_hardening() {
    section "e) hardening spot checks"
    if command_exists ss; then
        check "PostgreSQL listens on loopback only" assert_loopback_listener_strict 5432
        check "Redis listens on loopback only" assert_loopback_listener_strict 6379
        check "RabbitMQ AMQP listens on loopback only" assert_loopback_listener_strict 5672
        local n
        while IFS= read -r n; do
            [[ "$(service_port "${n}")" != "-" ]] || continue
            check "${n} listens on 127.0.0.1:$(service_port "${n}")" assert_loopback_listener_strict "$(service_port "${n}")"
        done < <(list_wired_services)
    else
        note "ss not installed: skipped listener checks"
    fi

    local f want
    for f in "${ESHOP_SECRETS_FILE}:600 root:root" "${ESHOP_ETC_DIR}/common.env:640 root:${ESHOP_GROUP}"; do
        want="${f#*:}"; f="${f%%:*}"
        if [[ -e "${f}" ]]; then
            if [[ "$(file_mode_owner "${f}")" == "${want}" ]]; then pass "${f} is ${want}"; else fail "${f} is $(file_mode_owner "${f}"), expected ${want}"; fi
        else
            fail "${f} does not exist or is not accessible (run verify.sh as root)"
        fi
    done
}

# Like assert_loopback_listener but a missing listener is a failure here.
assert_loopback_listener_strict() {
    local port=$1 lines addr
    lines="$(ss -H -ltn "sport = :${port}" 2>/dev/null || true)"
    [[ -n "${lines}" ]] || return 1
    while read -r _ _ _ addr _; do
        case "${addr}" in
            127.0.0.1:"${port}"|"[::1]:${port}") ;;
            *) return 1 ;;
        esac
    done <<<"${lines}"
}

# ---------------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wait) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "--wait needs a number of seconds"; WAIT_SECONDS=$2; shift 2 ;;
            -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    assert_service_table
    require_cmd curl

    printf 'eShop native stack verification (%s)\n' "$(hostname)"
    check_units
    check_catalog_http
    check_vector
    check_no_container_runtime
    check_hardening

    printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"
    if [[ "${FAIL}" -gt 0 ]]; then
        printf 'Failed checks:\n'
        printf '  - %s\n' "${FAILED_CHECKS[@]}"
        exit 1
    fi
    printf 'All checks passed.\n'
}

main "$@"
