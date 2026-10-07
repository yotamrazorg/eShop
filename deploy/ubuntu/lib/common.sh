#!/usr/bin/env bash
# deploy/ubuntu/lib/common.sh - shared helpers for the eShop native Ubuntu deployment.
#
# Source this file; do not execute it. It defines functions and constants only and
# has no side effects beyond setting variables, so it is safe to source from tests.
#
# Every helper here is idempotent: it inspects current state first and only acts
# when the state differs from what is wanted.
set -euo pipefail

if [[ -n "${ESHOP_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
ESHOP_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
# The deploy/ubuntu directory is located relative to this file, never via an
# absolute path baked into the repository.
ESHOP_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESHOP_REPO_DIR="$(cd "${ESHOP_DEPLOY_DIR}/../.." && pwd)"
ESHOP_LIB_DIR="${ESHOP_DEPLOY_DIR}/lib"
export ESHOP_DEPLOY_DIR ESHOP_REPO_DIR ESHOP_LIB_DIR

# Intended system install paths. They can be overridden through the environment
# so that the helper functions can be exercised by non-root self tests against a
# scratch directory (see deploy/ubuntu/tests). Real hosts never set these.
ESHOP_USER="${ESHOP_USER:-eshop}"
ESHOP_GROUP="${ESHOP_GROUP:-eshop}"
ESHOP_OPT_DIR="${ESHOP_OPT_DIR:-/opt/eshop}"
ESHOP_ETC_DIR="${ESHOP_ETC_DIR:-/etc/eshop}"
ESHOP_STATE_DIR="${ESHOP_STATE_DIR:-/var/lib/eshop}"
ESHOP_SYSTEMD_DIR="${ESHOP_SYSTEMD_DIR:-/etc/systemd/system}"
ESHOP_SECRETS_FILE="${ESHOP_SECRETS_FILE:-${ESHOP_ETC_DIR}/secrets.env}"

# ---------------------------------------------------------------------------
# Logging (stderr, so stdout stays usable for data)
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_BLU=$'\033[34m'; _C_RST=$'\033[0m'
else
    _C_RED=''; _C_YEL=''; _C_GRN=''; _C_BLU=''; _C_RST=''
fi

log_info()  { printf '%s[info]%s  %s\n' "${_C_BLU}" "${_C_RST}" "$*" >&2; }
log_ok()    { printf '%s[ ok ]%s  %s\n' "${_C_GRN}" "${_C_RST}" "$*" >&2; }
log_warn()  { printf '%s[warn]%s  %s\n' "${_C_YEL}" "${_C_RST}" "$*" >&2; }
log_error() { printf '%s[fail]%s  %s\n' "${_C_RED}" "${_C_RST}" "$*" >&2; }
log_step()  { printf '\n%s==> %s%s\n' "${_C_BLU}" "$*" "${_C_RST}" >&2; }

die() {
    log_error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "$(basename "$0") must be run as root (try: sudo $0 ...)"
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local c
    for c in "$@"; do
        command_exists "${c}" || die "required command not found: ${c}"
    done
}

# True when this host is booted with systemd as PID 1 (a container without
# systemd, or a chroot, returns false). Controlled by ESHOP_FORCE_NO_SYSTEMD=1.
have_systemd() {
    [[ "${ESHOP_FORCE_NO_SYSTEMD:-0}" != "1" ]] || return 1
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

# Validates that a generated/loaded secret only has characters that are safe in
# connection strings, URLs and env files without any escaping.
assert_alnum() {
    local name=$1 value=$2
    [[ "${value}" =~ ^[A-Za-z0-9]+$ ]] || die "${name} must be alphanumeric only (found unsupported characters)"
}

# ---------------------------------------------------------------------------
# Filesystem helpers (idempotent)
# ---------------------------------------------------------------------------
# ensure_dir PATH [MODE] [OWNER[:GROUP]]
ensure_dir() {
    local path=$1 mode=${2:-} owner=${3:-}
    [[ -d "${path}" ]] || { mkdir -p "${path}"; log_info "created directory ${path}"; }
    if [[ -n "${mode}" && "$(stat -c '%a' "${path}")" != "${mode#0}" ]]; then
        chmod "${mode}" "${path}"
    fi
    if [[ -n "${owner}" ]]; then
        local want_owner=${owner%%:*} want_group=""
        [[ "${owner}" == *:* ]] && want_group=${owner#*:}
        local cur_owner cur_group
        cur_owner="$(stat -c '%U' "${path}")"; cur_group="$(stat -c '%G' "${path}")"
        if [[ "${cur_owner}" != "${want_owner}" || ( -n "${want_group}" && "${cur_group}" != "${want_group}" ) ]]; then
            chown "${owner}" "${path}"
        fi
    fi
}

# ensure_line FILE LINE - append LINE to FILE unless an identical line exists.
ensure_line() {
    local file=$1 line=$2
    if [[ -f "${file}" ]] && grep -qxF -- "${line}" "${file}"; then
        return 0
    fi
    # Guarantee the previous last line is newline terminated before appending.
    if [[ -s "${file}" && -n "$(tail -c1 "${file}")" ]]; then
        printf '\n' >> "${file}"
    fi
    printf '%s\n' "${line}" >> "${file}"
    log_info "appended to ${file}: ${line}"
}

# ensure_kv FILE KEY VALUE - make FILE contain exactly one "KEY=VALUE" line for
# KEY (replace in place, otherwise append). Only for simple KEY=VALUE files.
ensure_kv() {
    local file=$1 key=$2 value=$3
    if [[ -f "${file}" ]] && grep -qxF -- "${key}=${value}" "${file}"; then
        return 0
    fi
    if [[ -f "${file}" ]] && grep -q -- "^${key}=" "${file}"; then
        local tmp
        tmp="$(mktemp "${file}.XXXXXX")"
        awk -v k="${key}" -v v="${value}" 'BEGIN{done=0} index($0, k "=")==1 { if(!done){print k "=" v; done=1}; next } {print}' "${file}" > "${tmp}"
        cat "${tmp}" > "${file}"   # keep inode, owner and mode of the original
        rm -f "${tmp}"
        log_info "updated ${key} in ${file}"
    else
        ensure_line "${file}" "${key}=${value}"
    fi
}

# write_file_if_changed DEST MODE OWNER:GROUP < content
# Writes stdin atomically to DEST (temp file in the same directory, then rename)
# only when the content, mode or ownership differ.
# Return status: 0 = DEST was created or changed, 1 = already up to date.
# Because of the non-zero "unchanged" status, call it inside an `if` / `||`:
#     if write_file_if_changed ...; then changed=1; fi
write_file_if_changed() {
    local dest=$1 mode=$2 owner=$3 tmp changed=1
    tmp="$(mktemp "${dest}.tmp.XXXXXX")"
    cat > "${tmp}"
    if [[ ! -f "${dest}" ]] || ! cmp -s "${tmp}" "${dest}"; then
        changed=0
    fi
    chmod "${mode}" "${tmp}"
    chown "${owner}" "${tmp}"
    if [[ "${changed}" -eq 0 ]]; then
        mv -f "${tmp}" "${dest}"
        log_info "wrote ${dest} (mode ${mode}, ${owner})"
        return 0
    fi
    # Content identical: still repair mode / ownership drift on the real file.
    rm -f "${tmp}"
    local cur_mode cur_owner
    cur_mode="$(stat -c '%a' "${dest}")"
    cur_owner="$(stat -c '%U:%G' "${dest}")"
    [[ "${cur_mode}" == "${mode#0}" ]] || chmod "${mode}" "${dest}"
    [[ "${cur_owner}" == "${owner}" ]] || chown "${owner}" "${dest}"
    return 1
}

# install_file_if_changed SRC DEST MODE OWNER:GROUP (same return convention)
install_file_if_changed() {
    local src=$1; shift
    [[ -f "${src}" ]] || die "missing source file: ${src}"
    write_file_if_changed "$@" < "${src}"
}

# ---------------------------------------------------------------------------
# apt helpers
# ---------------------------------------------------------------------------
_ESHOP_APT_UPDATED=0

apt_update_once() {
    if [[ "${_ESHOP_APT_UPDATED}" -eq 0 ]]; then
        log_info "apt-get update"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        _ESHOP_APT_UPDATED=1
    fi
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# apt_install PKG... - installs only the packages that are missing.
apt_install() {
    local missing=() p
    for p in "$@"; do
        pkg_installed "${p}" || missing+=("${p}")
    done
    if [[ "${#missing[@]}" -eq 0 ]]; then
        log_ok "apt packages already installed: $*"
        return 0
    fi
    apt_update_once
    log_info "apt-get install: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# ---------------------------------------------------------------------------
# Secrets file access (generation lives in steps-secrets.sh)
# ---------------------------------------------------------------------------
# secret_get KEY - print the value of KEY from the secrets file (empty if absent).
secret_get() {
    local key=$1
    [[ -f "${ESHOP_SECRETS_FILE}" ]] || return 0
    sed -n "s/^${key}=//p" "${ESHOP_SECRETS_FILE}" | head -n1
}

# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------
# render_template TEMPLATE VAR... - render TEMPLATE to stdout with envsubst,
# substituting ONLY the named variables (explicit whitelist: any other ${...}
# or $... in the template stays literal). Every whitelisted variable must be set
# and non-empty, and no whitelisted-style placeholder may remain unresolved.
# The output depends only on the template and the variable values, so repeated
# renders are byte-identical.
render_template() {
    local tmpl=$1; shift
    [[ -f "${tmpl}" ]] || die "template not found: ${tmpl}"
    require_cmd envsubst
    local v list='' out
    for v in "$@"; do
        [[ "${v}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid variable name in whitelist: ${v}"
        [[ -n "${!v:-}" ]] || die "variable ${v} is unset or empty (needed to render ${tmpl})"
        export "${v?}"
        list+="\${${v}} "
    done
    out="$(envsubst "${list}" < "${tmpl}")"
    if grep -qE '@[A-Z_]+@' <<<"${out}"; then
        die "unresolved @PLACEHOLDER@ left after rendering ${tmpl}"
    fi
    printf '%s\n' "${out}"
}

# render_at_template TEMPLATE NAME=VALUE... - replace @NAME@ tokens (used for
# systemd unit templates, where $ and % are meaningful to systemd and must not
# go through envsubst). Fails if any @TOKEN@ remains.
render_at_template() {
    local tmpl=$1; shift
    [[ -f "${tmpl}" ]] || die "template not found: ${tmpl}"
    local out kv k v
    out="$(cat "${tmpl}")"
    for kv in "$@"; do
        k=${kv%%=*}; v=${kv#*=}
        out="${out//@${k}@/${v}}"
    done
    if grep -qE '@[A-Z_]+@' <<<"${out}"; then
        die "unresolved placeholder in ${tmpl}: $(grep -oE '@[A-Z_]+@' <<<"${out}" | sort -u | tr '\n' ' ')"
    fi
    printf '%s\n' "${out}"
}

# ---------------------------------------------------------------------------
# systemd helpers (all degrade to a warning when systemd is not running)
# ---------------------------------------------------------------------------
warn_no_systemd() {
    log_warn "systemd is not running on this host (container/chroot?): skipped: $*"
}

sd_daemon_reload() {
    if have_systemd; then systemctl daemon-reload; else warn_no_systemd "systemctl daemon-reload"; fi
}

sd_enable() {
    if have_systemd; then systemctl enable "$@" >/dev/null; else warn_no_systemd "systemctl enable $*"; fi
}

sd_is_active() {
    have_systemd && systemctl is-active --quiet "$1"
}

# ---------------------------------------------------------------------------
# PostgreSQL helpers
# ---------------------------------------------------------------------------
# as_postgres CMD... - run a command as the postgres OS user (peer auth on the
# local socket). Uses runuser (util-linux, always present) when root.
as_postgres() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        runuser -u postgres -- "$@"
    else
        sudo -n -u postgres "$@"
    fi
}

# psql_admin [psql args...] - psql as the postgres superuser, quiet, fail-fast.
# SQL is read from stdin or passed with -c / -d, so secrets never appear in argv.
psql_admin() {
    as_postgres psql -X -q -v ON_ERROR_STOP=1 "$@"
}

# ---------------------------------------------------------------------------
# Distro service lifecycle (postgresql / redis-server / rabbitmq-server)
# ---------------------------------------------------------------------------
# These work on real hosts through systemd. In a container without systemd they
# fall back to the SysV `service` wrapper shipped by the Debian packages, and if
# even that is unavailable they only warn - provisioning keeps going so the
# remaining (file based) steps can still be exercised.
# svc_ctl VERB NAME - systemctl VERB NAME; without systemd fall back to SysV `service`, then to a warning.
svc_ctl() {
    local verb=$1 name=$2
    if have_systemd; then
        systemctl "${verb}" "${name}"
    elif command_exists service; then
        log_warn "no systemd: using 'service ${name} ${verb}'"
        service "${name}" "${verb}" || log_warn "service ${name} ${verb} failed"
    else
        warn_no_systemd "${verb} ${name}"
    fi
}
svc_start()   { svc_ctl start "$1"; }
svc_restart() { svc_ctl restart "$1"; }

# wait_until TIMEOUT_SECONDS DESCRIPTION CMD... - poll CMD once a second.
wait_until() {
    local timeout=$1 desc=$2; shift 2
    local i
    for ((i = 0; i < timeout; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    log_error "timed out after ${timeout}s waiting for: ${desc}"
    return 1
}

# fail_or_warn MESSAGE - fatal on a systemd host, warning in a systemd-less container.
fail_or_warn() {
    if have_systemd; then die "$*"; else log_warn "$* (continuing: no systemd on this host)"; fi
}

# file_fingerprint FILE... - hash of the combined contents (empty hash if missing).
file_fingerprint() {
    local f
    for f in "$@"; do cat "${f}" 2>/dev/null || true; done | sha256sum | cut -d' ' -f1
}

# assert_loopback_listener PORT NAME - if something listens on PORT it must be
# bound to loopback only. Returns 0 when not listening (unknown), 1 when exposed.
assert_loopback_listener() {
    local port=$1 name=$2 line addr bad=0 seen=0
    command_exists ss || { log_warn "ss not available; cannot verify ${name} loopback binding"; return 0; }
    while read -r line; do
        [[ -n "${line}" ]] || continue
        seen=1
        addr="$(awk '{print $4}' <<<"${line}")"
        case "${addr}" in
            127.0.0.1:"${port}"|"[::1]:${port}") ;;
            *) log_error "${name} listens on ${addr} (expected loopback only)"; bad=1 ;;
        esac
    done < <(ss -H -ltn "sport = :${port}" 2>/dev/null)
    if [[ "${seen}" -eq 0 ]]; then
        log_warn "nothing is listening on ${port} (${name} not running?)"
        return 0
    fi
    [[ "${bad}" -eq 0 ]]
}
