#!/usr/bin/env bash
# steps-secrets.sh - generate-once secrets in a root-only file.
#
# /etc/eshop/secrets.env (0600 root:root) holds KEY=VALUE lines. Keys are only
# ever ADDED when missing; an existing value is never regenerated, so credentials
# already applied to PostgreSQL / Redis / RabbitMQ stay valid across re-runs. The
# steps for those services re-apply the stored value to the service so a manually
# restored or changed service converges back to the file.
#
# Values are alphanumeric only (see secret_generate) so they can be embedded in
# Npgsql keyword strings, amqp:// URIs and EnvironmentFile lines without escaping.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Later milestones append their own keys here.
ESHOP_SECRET_KEYS=(POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD)
ESHOP_SECRET_LENGTH="${ESHOP_SECRET_LENGTH:-32}"

# secret_generate [LENGTH] - random alphanumeric string from the kernel CSPRNG.
secret_generate() {
    local len=${1:-${ESHOP_SECRET_LENGTH}} s
    # tr is killed by SIGPIPE once head has enough bytes; pipefail is disabled in the subshell for that.
    s="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${len}")"
    [[ "${#s}" -eq "${len}" ]] || die "failed to generate a ${len}-character secret"
    printf '%s' "${s}"
}

# step_secrets - create the secrets file if needed and add any missing key.
step_secrets() {
    log_step "Secrets (${ESHOP_SECRETS_FILE})"
    ensure_dir "${ESHOP_ETC_DIR}" 0750 "root:${ESHOP_GROUP}"

    if [[ ! -e "${ESHOP_SECRETS_FILE}" ]]; then
        # umask first so the file never exists with looser permissions.
        ( umask 077; : > "${ESHOP_SECRETS_FILE}" )
        log_info "created ${ESHOP_SECRETS_FILE}"
    fi
    chmod 0600 "${ESHOP_SECRETS_FILE}"
    chown root:root "${ESHOP_SECRETS_FILE}"

    local key value added=0
    for key in "${ESHOP_SECRET_KEYS[@]}"; do
        value="$(secret_get "${key}")"
        if [[ -z "${value}" ]]; then
            if grep -q "^${key}=" "${ESHOP_SECRETS_FILE}"; then
                # Present but empty: drop the empty line, then generate.
                sed -i "/^${key}=\$/d" "${ESHOP_SECRETS_FILE}"
            fi
            ensure_line "${ESHOP_SECRETS_FILE}" "${key}=$(secret_generate)"
            added=$((added + 1))
            log_info "generated new secret ${key}"
        else
            assert_alnum "${key}" "${value}"
        fi
    done
    if [[ "${added}" -eq 0 ]]; then
        log_ok "all secrets already present (none regenerated)"
    fi
}

# load_secrets - export every key from ESHOP_SECRET_KEYS into the current shell.
# The file is parsed, never `source`d, and only whitelisted keys are exported.
load_secrets() {
    [[ -f "${ESHOP_SECRETS_FILE}" ]] || die "secrets file missing: ${ESHOP_SECRETS_FILE} (run the secrets step first)"
    local key value
    for key in "${ESHOP_SECRET_KEYS[@]}"; do
        value="$(secret_get "${key}")"
        [[ -n "${value}" ]] || die "secret ${key} missing in ${ESHOP_SECRETS_FILE}"
        assert_alnum "${key}" "${value}"
        printf -v "${key}" '%s' "${value}"
        export "${key?}"
    done
}
