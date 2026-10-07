#!/usr/bin/env bash
# steps-env.sh - render env/*.env.tmpl into /etc/eshop/*.env (0640 root:eshop).
#
# Rendering is deterministic (no timestamps, fixed variable order) and uses an
# explicit envsubst whitelist, so re-running with unchanged secrets rewrites
# nothing and only variables listed below can ever be substituted.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=services.sh
source "$(dirname "${BASH_SOURCE[0]}")/services.sh"
# shellcheck source=steps-secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/steps-secrets.sh"
# shellcheck source=steps-postgres.sh
source "$(dirname "${BASH_SOURCE[0]}")/steps-postgres.sh"
# shellcheck source=steps-rabbitmq.sh
source "$(dirname "${BASH_SOURCE[0]}")/steps-rabbitmq.sh"

ESHOP_ENV_TEMPLATE_DIR="${ESHOP_ENV_TEMPLATE_DIR:-${ESHOP_DEPLOY_DIR}/env}"

# The ONLY variables envsubst may substitute. Every one must be set and non-empty.
ESHOP_ENV_WHITELIST=(
    POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD
    ESHOP_PG_ROLE ESHOP_RABBITMQ_USER ESHOP_RABBITMQ_VHOST
    ESHOP_SERVICES_DOC ESHOP_CONFIG_ARGS
    SERVICE_NAME SERVICE_PORT
)

# env_prepare_vars [SERVICE] - set the non-secret template variables. SERVICE
# supplies SERVICE_NAME / SERVICE_PORT (placeholders are used for the common file).
env_prepare_vars() {
    local svc=${1:-}
    local line doc=''
    while IFS= read -r line; do
        doc+="${doc:+$'\n'}# ${line}"
    done < <(service_discovery_lines)
    ESHOP_SERVICES_DOC="${doc}"
    ESHOP_CONFIG_ARGS="$(service_discovery_args)"
    if [[ -n "${svc}" ]]; then
        SERVICE_NAME="${svc}"
        SERVICE_PORT="$(service_port "${svc}")"
    else
        SERVICE_NAME="common"
        SERVICE_PORT="0"
    fi
}

# render_env_file TEMPLATE_NAME [SERVICE] - render to stdout.
render_env_file() {
    local tmpl="${ESHOP_ENV_TEMPLATE_DIR}/$1" svc=${2:-}
    env_prepare_vars "${svc}"
    render_template "${tmpl}" "${ESHOP_ENV_WHITELIST[@]}"
}

# install_env_file TEMPLATE_NAME DEST [SERVICE] - render and install (0640 root:eshop).
install_env_file() {
    local tmpl=$1 dest=$2 svc=${3:-} content
    content="$(render_env_file "${tmpl}" "${svc}")"   # a render failure aborts here, before anything is written
    if printf '%s\n' "${content}" | write_file_if_changed "${dest}" 0640 "root:${ESHOP_GROUP}"; then
        :
    else
        log_ok "${dest} unchanged"
    fi
}

step_env() {
    log_step "Environment files (${ESHOP_ETC_DIR})"
    load_secrets
    ensure_dir "${ESHOP_ETC_DIR}" 0750 "root:${ESHOP_GROUP}"

    install_env_file common.env.tmpl "${ESHOP_ETC_DIR}/common.env"

    local svc
    while IFS= read -r svc; do
        [[ -f "${ESHOP_ENV_TEMPLATE_DIR}/${svc}.env.tmpl" ]] \
            || die "service ${svc} is wired but ${ESHOP_ENV_TEMPLATE_DIR}/${svc}.env.tmpl does not exist"
        install_env_file "${svc}.env.tmpl" "$(service_env_file "${svc}")" "${svc}"
    done < <(list_wired_services)
}
