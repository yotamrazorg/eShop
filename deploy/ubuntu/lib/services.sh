#!/usr/bin/env bash
# deploy/ubuntu/lib/services.sh - the eShop service table.
#
# One row per deployable service. Later milestones add services by FLIPPING the
# `wired` column to `yes` (and shipping the matching env template / unit) or by
# APPENDING a row; no provisioning/publish logic has to change because every
# script iterates over this table.
#
# Columns (pipe separated):
#   name           service / unit stem; systemd unit is eshop-<name>.service,
#                  env file is /etc/eshop/<name>.env, install dir /opt/eshop/<name>.
#                  Names match the Aspire AppHost resource names so the
#                  Services__<name>__http__0 service-discovery keys line up.
#   port           loopback HTTP port (ASPNETCORE_URLS); "-" for background workers
#   project        project directory relative to the repository root
#   assembly       entry assembly (<assembly>.dll); equals the project folder name
#                  because no csproj overrides AssemblyName
#   user           system user the unit runs as
#   wired          yes|no - only wired services are published, get env files,
#                  units and are checked by verify.sh in the current milestone
#   required_paths comma separated files/dirs (relative to the publish dir) that
#                  must exist after publish; empty for none
#
# Ports are fixed by the deployment contract (see README / PROJECT.md).
# shellcheck shell=bash

if [[ -n "${ESHOP_SERVICES_SH_LOADED:-}" ]]; then
    return 0
fi
ESHOP_SERVICES_SH_LOADED=1

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ESHOP_SERVICES=(
    "basket-api|5221|src/Basket.API|Basket.API|eshop|no|"
    "catalog-api|5222|src/Catalog.API|Catalog.API|eshop|yes|Setup/catalog.json,Pics"
    "identity-api|5223|src/Identity.API|Identity.API|eshop|no|"
    "ordering-api|5224|src/Ordering.API|Ordering.API|eshop|no|"
    "order-processor|-|src/OrderProcessor|OrderProcessor|eshop|no|"
    "payment-processor|5226|src/PaymentProcessor|PaymentProcessor|eshop|no|"
    "webhooks-api|5227|src/Webhooks.API|Webhooks.API|eshop|no|"
    "webapp|5045|src/WebApp|WebApp|eshop|no|"
    "webhooksclient|5062|src/WebhookClient|WebhookClient|eshop|no|"
)

# Column indexes
readonly _SVC_NAME=0 _SVC_PORT=1 _SVC_PROJECT=2 _SVC_ASSEMBLY=3 _SVC_USER=4 _SVC_WIRED=5 _SVC_REQUIRED=6

# service_row NAME - print the raw table row; non-zero if the service is unknown.
service_row() {
    local want=$1 row
    for row in "${ESHOP_SERVICES[@]}"; do
        if [[ "${row%%|*}" == "${want}" ]]; then
            printf '%s\n' "${row}"
            return 0
        fi
    done
    return 1
}

service_exists() { service_row "$1" >/dev/null; }

# _service_field NAME INDEX
_service_field() {
    local name=$1 idx=$2 row
    row="$(service_row "${name}")" || { log_error "unknown service: ${name}"; return 1; }
    local -a f
    IFS='|' read -r -a f <<<"${row}|"   # trailing '|' keeps an empty last column
    printf '%s\n' "${f[idx]}"
}

service_port()          { _service_field "$1" "${_SVC_PORT}"; }
service_project()       { _service_field "$1" "${_SVC_PROJECT}"; }
service_assembly()      { _service_field "$1" "${_SVC_ASSEMBLY}"; }
service_user()          { _service_field "$1" "${_SVC_USER}"; }
service_required_paths(){ _service_field "$1" "${_SVC_REQUIRED}"; }

service_wired() {
    local w
    w="$(_service_field "$1" "${_SVC_WIRED}")" || return 1
    [[ "${w}" == "yes" ]]
}

service_unit()        { printf 'eshop-%s.service\n' "$1"; }
service_install_dir() { printf '%s/%s\n' "${ESHOP_OPT_DIR}" "$1"; }
service_env_file()    { printf '%s/%s.env\n' "${ESHOP_ETC_DIR}" "$1"; }

# list_services - every service name, in table order.
list_services() {
    local row
    for row in "${ESHOP_SERVICES[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# list_wired_services - only the services wired in the current milestone.
list_wired_services() {
    local n
    while IFS= read -r n; do
        if service_wired "${n}"; then printf '%s\n' "${n}"; fi
    done < <(list_services)
}

# service_endpoint NAME - http://<loopback>:PORT (empty for services without a port).
service_endpoint() {
    local p
    p="$(service_port "$1")" || return 1
    [[ "${p}" == "-" ]] || printf 'http://%s:%s\n' "${ESHOP_LOOPBACK_ADDR}" "${p}"
}

# service_discovery_lines - the contract keys Services__<name>__http__0=<url>,
# one per service that has a port (deterministic, table order).
service_discovery_lines() {
    local n e
    while IFS= read -r n; do
        e="$(service_endpoint "${n}")"
        [[ -z "${e}" ]] || printf 'Services__%s__http__0=%s\n' "${n}" "${e}"
    done < <(list_services)
}

# service_discovery_args - the same endpoints as .NET command-line configuration
# arguments (--Services:<name>:http:0=<url>), space separated on one line.
# Why both forms exist: systemd's EnvironmentFile= only accepts variable names made
# of [A-Za-z0-9_], so Services__catalog-api__http__0 (a dash in the service name)
# is rejected by systemd ("Invalid environment variable name"). Units therefore
# pass the endpoints as arguments, which the ASP.NET Core host maps to the very
# same configuration keys (Services:<name>:http:0).
service_discovery_args() {
    local n e out=''
    while IFS= read -r n; do
        e="$(service_endpoint "${n}")"
        [[ -z "${e}" ]] || out+="${out:+ }--Services:${n}:http:0=${e}"
    done < <(list_services)
    printf '%s\n' "${out}"
}

# assert_service_table - sanity checks used by provision/publish/tests.
assert_service_table() {
    local row n seen=' ' ports=' '
    local -a f
    for row in "${ESHOP_SERVICES[@]}"; do
        IFS='|' read -r -a f <<<"${row}|"
        n=${f[0]}
        [[ ${#f[@]} -eq 7 ]] || { log_error "malformed service row: ${row}"; return 1; }
        [[ "${seen}" != *" ${n} "* ]] || { log_error "duplicate service name: ${n}"; return 1; }
        seen+="${n} "
        if [[ "${f[1]}" != "-" ]]; then
            [[ "${f[1]}" =~ ^[0-9]+$ ]] || { log_error "bad port for ${n}: ${f[1]}"; return 1; }
            [[ "${ports}" != *" ${f[1]} "* ]] || { log_error "duplicate port ${f[1]} (${n})"; return 1; }
            ports+="${f[1]} "
        fi
        [[ "${f[5]}" == "yes" || "${f[5]}" == "no" ]] || { log_error "wired must be yes|no for ${n}"; return 1; }
    done
}
