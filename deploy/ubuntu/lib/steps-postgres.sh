#!/usr/bin/env bash
# steps-postgres.sh - PostgreSQL 16 + pgvector: loopback only, scram-sha-256,
# role/databases/extension. Safe to re-run: every change is conditional and the
# role password is re-applied from /etc/eshop/secrets.env on each run.
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ESHOP_PG_VERSION="${ESHOP_PG_VERSION:-16}"
ESHOP_PG_CLUSTER="${ESHOP_PG_CLUSTER:-main}"
ESHOP_PG_ROLE="${ESHOP_PG_ROLE:-eshop}"
ESHOP_PG_DATABASES=(catalogdb identitydb orderingdb webhooksdb)
ESHOP_PG_VECTOR_DATABASES=(catalogdb)
ESHOP_PG_CONF_DIR="/etc/postgresql/${ESHOP_PG_VERSION}/${ESHOP_PG_CLUSTER}"
ESHOP_PG_HBA_BEGIN="# BEGIN eshop managed (provision-host.sh) - do not edit between markers"
ESHOP_PG_HBA_END="# END eshop managed"

pg_cluster_online() {
    pg_lsclusters -h 2>/dev/null | awk -v v="${ESHOP_PG_VERSION}" -v c="${ESHOP_PG_CLUSTER}" '$1==v && $2==c && $4=="online"{f=1} END{exit !f}'
}

pg_cluster_exists() {
    pg_lsclusters -h 2>/dev/null | awk -v v="${ESHOP_PG_VERSION}" -v c="${ESHOP_PG_CLUSTER}" '$1==v && $2==c{f=1} END{exit !f}'
}

pg_ready_socket() { pg_isready -q -h /var/run/postgresql; }

pg_start_cluster() {
    if have_systemd; then
        systemctl start "postgresql@${ESHOP_PG_VERSION}-${ESHOP_PG_CLUSTER}"
    else
        pg_ctlcluster "${ESHOP_PG_VERSION}" "${ESHOP_PG_CLUSTER}" start
    fi
}

pg_restart_cluster() {
    if have_systemd; then
        systemctl restart "postgresql@${ESHOP_PG_VERSION}-${ESHOP_PG_CLUSTER}"
    else
        pg_ctlcluster "${ESHOP_PG_VERSION}" "${ESHOP_PG_CLUSTER}" restart
    fi
}

# pg_scalar SQL [DB] - single value query as the postgres superuser.
pg_scalar() {
    local sql=$1 db=${2:-postgres}
    psql_admin -d "${db}" -tA -c "${sql}"
}

# Rewrite pg_hba.conf with a managed block FIRST, so the first-match rule for
# loopback TCP is always scram-sha-256 whatever the packaging default was. The
# Debian default `local ... peer` rules (used by `sudo -u postgres psql`) are kept.
pg_hba_desired() {
    local hba=$1
    printf '%s\n' "${ESHOP_PG_HBA_BEGIN}"
    printf '%s\n' "host    all             all             127.0.0.1/32            scram-sha-256"
    printf '%s\n' "host    all             all             ::1/128                 scram-sha-256"
    printf '%s\n' "${ESHOP_PG_HBA_END}"
    awk -v b="${ESHOP_PG_HBA_BEGIN}" -v e="${ESHOP_PG_HBA_END}" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip   { print }' "${hba}"
}

step_postgres() {
    log_step "PostgreSQL ${ESHOP_PG_VERSION} + pgvector"
    require_cmd pg_lsclusters pg_isready psql
    load_secrets

    if ! pg_cluster_exists; then
        log_info "creating cluster ${ESHOP_PG_VERSION}/${ESHOP_PG_CLUSTER}"
        pg_createcluster "${ESHOP_PG_VERSION}" "${ESHOP_PG_CLUSTER}"
    fi
    [[ -d "${ESHOP_PG_CONF_DIR}" ]] || die "PostgreSQL config dir not found: ${ESHOP_PG_CONF_DIR}"

    local restart_needed=0 reload_needed=0

    # --- listen on loopback only; scram password hashing --------------------------------
    # postgresql.conf has `include_dir = 'conf.d'` on Debian/Ubuntu; make sure of it.
    local main_conf="${ESHOP_PG_CONF_DIR}/postgresql.conf"
    if ! grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "${main_conf}"; then
        ensure_line "${main_conf}" "include_dir = 'conf.d'"
        restart_needed=1
    fi
    ensure_dir "${ESHOP_PG_CONF_DIR}/conf.d" 0755 postgres:postgres
    if write_file_if_changed "${ESHOP_PG_CONF_DIR}/conf.d/90-eshop.conf" 0644 postgres:postgres <<'CONF'
# Managed by eshop provision-host.sh. PostgreSQL is reachable on loopback only.
listen_addresses = '127.0.0.1'
port = 5432
password_encryption = 'scram-sha-256'
CONF
    then
        restart_needed=1
    fi

    # --- authentication ----------------------------------------------------------------
    local hba="${ESHOP_PG_CONF_DIR}/pg_hba.conf"
    if write_file_if_changed "${hba}" 0640 postgres:postgres < <(pg_hba_desired "${hba}"); then
        reload_needed=1
    fi

    # --- make sure the cluster is running with the new settings -------------------------
    if ! pg_cluster_online; then
        log_info "starting PostgreSQL cluster"
        pg_start_cluster
    elif [[ "${restart_needed}" -eq 1 ]]; then
        log_info "restarting PostgreSQL (listen_addresses changed)"
        pg_restart_cluster
    fi
    wait_until 60 "PostgreSQL to accept connections" pg_ready_socket \
        || { fail_or_warn "PostgreSQL did not become ready"; return 0; }
    if [[ "${reload_needed}" -eq 1 ]]; then
        psql_admin -c "SELECT pg_reload_conf()" >/dev/null
        log_info "reloaded PostgreSQL configuration (pg_hba.conf)"
    fi

    # Verify the effective settings rather than trusting the files.
    local listen
    listen="$(pg_scalar "SHOW listen_addresses")"
    if [[ "${listen}" != "127.0.0.1" ]]; then
        log_warn "listen_addresses is '${listen}', restarting to apply '127.0.0.1'"
        pg_restart_cluster
        wait_until 60 "PostgreSQL restart" pg_ready_socket || die "PostgreSQL did not come back after restart"
        listen="$(pg_scalar "SHOW listen_addresses")"
        [[ "${listen}" == "127.0.0.1" ]] || die "PostgreSQL listen_addresses is '${listen}', expected 127.0.0.1"
    fi
    assert_loopback_listener 5432 PostgreSQL || die "PostgreSQL is not restricted to loopback"
    log_ok "PostgreSQL listens on loopback only, scram-sha-256 for TCP"

    # --- role (password always re-applied from secrets.env) -----------------------------
    assert_alnum POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
    psql_admin <<SQL
SET password_encryption = 'scram-sha-256';
DO \$do\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ESHOP_PG_ROLE}') THEN
        CREATE ROLE ${ESHOP_PG_ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${POSTGRES_PASSWORD}';
    ELSE
        ALTER ROLE ${ESHOP_PG_ROLE} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '${POSTGRES_PASSWORD}';
    END IF;
END
\$do\$;
SQL
    log_ok "role ${ESHOP_PG_ROLE} present with the password from secrets.env"

    # --- databases ---------------------------------------------------------------------
    local db
    for db in "${ESHOP_PG_DATABASES[@]}"; do
        if [[ -z "$(pg_scalar "SELECT 1 FROM pg_database WHERE datname = '${db}'")" ]]; then
            psql_admin -c "CREATE DATABASE ${db} OWNER ${ESHOP_PG_ROLE}"
            log_info "created database ${db}"
        elif [[ "$(pg_scalar "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${db}'")" != "${ESHOP_PG_ROLE}" ]]; then
            psql_admin -c "ALTER DATABASE ${db} OWNER TO ${ESHOP_PG_ROLE}"
            log_info "changed owner of ${db} to ${ESHOP_PG_ROLE}"
        fi
        # Only the owner (and superusers) may connect.
        psql_admin -c "REVOKE ALL ON DATABASE ${db} FROM PUBLIC"
    done
    log_ok "databases present and owned by ${ESHOP_PG_ROLE}: ${ESHOP_PG_DATABASES[*]}"

    # --- pgvector ----------------------------------------------------------------------
    if [[ -z "$(pg_scalar "SELECT 1 FROM pg_available_extensions WHERE name = 'vector'")" ]]; then
        die "the pgvector extension 'vector' is not available to PostgreSQL ${ESHOP_PG_VERSION}. Install it with: apt-get install postgresql-${ESHOP_PG_VERSION}-pgvector (then re-run provision-host.sh)"
    fi
    for db in "${ESHOP_PG_VECTOR_DATABASES[@]}"; do
        psql_admin -d "${db}" -c "CREATE EXTENSION IF NOT EXISTS vector"
    done
    log_ok "extension vector enabled in: ${ESHOP_PG_VECTOR_DATABASES[*]}"

    # --- prove the credentials work over loopback TCP ------------------------------------
    if PGPASSWORD="${POSTGRES_PASSWORD}" psql -X -q -h 127.0.0.1 -p 5432 -U "${ESHOP_PG_ROLE}" -d catalogdb -tA -c "SELECT 1" >/dev/null 2>&1; then
        log_ok "scram login as ${ESHOP_PG_ROLE}@127.0.0.1/catalogdb works"
    else
        die "cannot log in as ${ESHOP_PG_ROLE} over 127.0.0.1 with the secrets.env password"
    fi
    if PGPASSWORD="wrong-${POSTGRES_PASSWORD}" psql -X -q -h 127.0.0.1 -p 5432 -U "${ESHOP_PG_ROLE}" -d catalogdb -tA -c "SELECT 1" >/dev/null 2>&1; then
        die "PostgreSQL accepted a wrong password over TCP: authentication is not enforced"
    fi
}
