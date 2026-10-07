#!/usr/bin/env bash
# tests/test-lib.sh - self tests for the pure helpers of deploy/ubuntu (no root, no
# network, no packages installed, nothing outside a scratch directory is touched).
#
# Usage: deploy/ubuntu/tests/test-lib.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

# Point every install path at the scratch directory before sourcing the libraries.
export ESHOP_OPT_DIR="${SCRATCH}/opt" ESHOP_ETC_DIR="${SCRATCH}/etc" ESHOP_STATE_DIR="${SCRATCH}/var"
export ESHOP_SYSTEMD_DIR="${SCRATCH}/systemd" ESHOP_SECRETS_FILE="${SCRATCH}/etc/secrets.env"
export NO_COLOR=1

# shellcheck source=../lib/common.sh
source "${DEPLOY_DIR}/lib/common.sh"
# shellcheck source=../lib/services.sh
source "${DEPLOY_DIR}/lib/services.sh"
# shellcheck source=../lib/steps-dotnet.sh
source "${DEPLOY_DIR}/lib/steps-dotnet.sh"
# shellcheck source=../lib/steps-secrets.sh
source "${DEPLOY_DIR}/lib/steps-secrets.sh"
# shellcheck source=../lib/steps-env.sh
source "${DEPLOY_DIR}/lib/steps-env.sh"
# shellcheck source=../lib/steps-systemd.sh
source "${DEPLOY_DIR}/lib/steps-systemd.sh"

T_PASS=0
T_FAIL=0
ok()   { T_PASS=$((T_PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { T_FAIL=$((T_FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# expect_true DESC CMD... / expect_false DESC CMD...
expect_true()  { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi; }
expect_false() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "${d}"; else ok "${d}"; fi; }
expect_eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "service table"
expect_true  "table is consistent (unique names/ports, wired yes|no)" assert_service_table
expect_eq    "only catalog-api is wired" "$(list_wired_services | tr '\n' ' ')" "catalog-api "
expect_eq    "catalog port" "$(service_port catalog-api)" "5222"
expect_eq    "catalog project" "$(service_project catalog-api)" "src/Catalog.API"
expect_eq    "catalog assembly" "$(service_assembly catalog-api)" "Catalog.API"
expect_eq    "catalog user" "$(service_user catalog-api)" "eshop"
expect_eq    "catalog unit" "$(service_unit catalog-api)" "eshop-catalog-api.service"
expect_eq    "catalog install dir" "$(service_install_dir catalog-api)" "${ESHOP_OPT_DIR}/catalog-api"
expect_false "unknown service is rejected" service_exists nope
declare -A want_ports=([basket-api]=5221 [catalog-api]=5222 [identity-api]=5223 [ordering-api]=5224
    [payment-processor]=5226 [webhooks-api]=5227 [webapp]=5045 [webhooksclient]=5062 [order-processor]=-)
for s in "${!want_ports[@]}"; do
    expect_eq "port of ${s}" "$(service_port "${s}")" "${want_ports[${s}]}"
done
for s in $(list_services); do
    [[ -d "${DEPLOY_DIR}/../../$(service_project "${s}")" ]] && ok "project dir of ${s} exists" || bad "project dir of ${s} exists"
done
expect_eq "discovery key for catalog-api" "$(service_discovery_lines | grep catalog-api)" "Services__catalog-api__http__0=http://127.0.0.1:5222"
expect_true "discovery args contain --Services:catalog-api:http:0" grep -q -- '--Services:catalog-api:http:0=http://127.0.0.1:5222' <<<"$(service_discovery_args)"

echo "global.json / SDK satisfaction"
GJ="${DEPLOY_DIR}/../../global.json"
expect_eq "global.json version parsed" "$(global_json_sdk_version "${GJ}")" "$(sed -n 's/.*"version": "\([0-9.]*\)".*/\1/p' "${GJ}" | head -n1)"
expect_eq "rollForward parsed" "$(global_json_roll_forward "${GJ}")" "latestFeature"
expect_eq "allowPrerelease parsed" "$(global_json_allow_prerelease "${GJ}")" "false"
sat() { dotnet_sdk_candidate_ok "$@"; }
expect_true  "10.0.302 satisfies 10.0.302 (latestFeature)"         sat 10.0.302 10.0.302 latestFeature false
expect_true  "10.0.305 satisfies (higher patch)"                    sat 10.0.302 10.0.305 latestFeature false
expect_true  "10.0.400 satisfies (higher feature band)"             sat 10.0.302 10.0.400 latestFeature false
expect_true  "10.0.399 satisfies (same band, higher patch)"         sat 10.0.302 10.0.399 latestFeature false
expect_false "10.0.301 does not satisfy (lower patch)"              sat 10.0.302 10.0.301 latestFeature false
expect_false "10.0.203 does not satisfy (lower feature band)"       sat 10.0.302 10.0.203 latestFeature false
expect_false "10.0.100 (apt noble band) does not satisfy"           sat 10.0.302 10.0.100 latestFeature false
expect_false "10.1.100 does not satisfy (different minor)"          sat 10.0.302 10.1.100 latestFeature false
expect_false "9.0.400 does not satisfy (different major)"           sat 10.0.302 9.0.400 latestFeature false
expect_false "11.0.100 does not satisfy (latestFeature keeps major)" sat 10.0.302 11.0.100 latestFeature false
expect_false "10.0.400-preview.1 rejected without allowPrerelease"  sat 10.0.302 10.0.400-preview.1 latestFeature false
expect_true  "10.0.400-preview.1 accepted with allowPrerelease"     sat 10.0.302 10.0.400-preview.1 latestFeature true
expect_true  "patch policy: 10.0.305"                               sat 10.0.302 10.0.305 patch false
expect_false "patch policy: 10.0.400 rejected"                      sat 10.0.302 10.0.400 patch false
expect_true  "minor policy: 10.1.100"                               sat 10.0.302 10.1.100 latestMinor false
expect_true  "major policy: 11.0.100"                               sat 10.0.302 11.0.100 latestMajor false
expect_false "disable policy: other version"                        sat 10.0.302 10.0.303 disable false
expect_true  "disable policy: exact"                                sat 10.0.302 10.0.302 disable false
expect_true  "satisfied by ANY of several installed SDKs"           dotnet_sdk_satisfies 10.0.302 latestFeature false 8.0.404 10.0.100 10.0.302
expect_false "not satisfied when none qualify"                      dotnet_sdk_satisfies 10.0.302 latestFeature false 8.0.404 10.0.100
expect_eq "apt candidate version parsing" "$(sed -n 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' <<<"10.0.100-0ubuntu1~24.04.1")" "10.0.100"

echo "file helpers"
mkdir -p "${SCRATCH}/f"
me="$(id -un):$(id -gn)"
if write_file_if_changed "${SCRATCH}/f/a" 0640 "${me}" <<<"hello"; then ok "first write reports changed"; else bad "first write reports changed"; fi
if write_file_if_changed "${SCRATCH}/f/a" 0640 "${me}" <<<"hello"; then bad "identical rewrite reports unchanged"; else ok "identical rewrite reports unchanged"; fi
expect_eq "mode applied" "$(stat -c %a "${SCRATCH}/f/a")" "640"
chmod 0600 "${SCRATCH}/f/a"
write_file_if_changed "${SCRATCH}/f/a" 0640 "${me}" <<<"hello" || true
expect_eq "mode drift repaired" "$(stat -c %a "${SCRATCH}/f/a")" "640"
if write_file_if_changed "${SCRATCH}/f/a" 0640 "${me}" <<<"changed"; then ok "content change reports changed"; else bad "content change reports changed"; fi
printf 'A=1\nB=2' > "${SCRATCH}/f/kv"
ensure_line "${SCRATCH}/f/kv" "C=3"; ensure_line "${SCRATCH}/f/kv" "C=3"
expect_eq "ensure_line appends exactly once" "$(grep -c '^C=3$' "${SCRATCH}/f/kv")" "1"
expect_eq "ensure_line fixes missing trailing newline" "$(sed -n 2p "${SCRATCH}/f/kv")" "B=2"
ensure_kv "${SCRATCH}/f/kv" A 9; ensure_kv "${SCRATCH}/f/kv" A 9
expect_eq "ensure_kv replaces in place" "$(grep -c '^A=' "${SCRATCH}/f/kv")/$(grep '^A=' "${SCRATCH}/f/kv")" "1/A=9"
ensure_dir "${SCRATCH}/f/d" 0750; ensure_dir "${SCRATCH}/f/d" 0750
expect_eq "ensure_dir mode" "$(stat -c %a "${SCRATCH}/f/d")" "750"

echo "secrets"
s1="$(secret_generate)"; s2="$(secret_generate)"
expect_eq "secret length" "${#s1}" "32"
expect_true "secret is alphanumeric" assert_alnum x "${s1}"
[[ "${s1}" != "${s2}" ]] && ok "secrets differ" || bad "secrets differ"
expect_false "non-alnum secret rejected" bash -c 'source "$1"; assert_alnum x "a b"' _ "${DEPLOY_DIR}/lib/common.sh"

echo "template rendering / env contract"
mkdir -p "${ESHOP_ETC_DIR}"
POSTGRES_PASSWORD=pgPass1 REDIS_PASSWORD=redisPass2 RABBITMQ_PASSWORD=mqPass3
export POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD
common1="$(render_env_file common.env.tmpl)"
common2="$(render_env_file common.env.tmpl)"
cat1="$(render_env_file catalog-api.env.tmpl catalog-api)"
cat2="$(render_env_file catalog-api.env.tmpl catalog-api)"
expect_eq "common.env rendering is deterministic" "${common1}" "${common2}"
expect_eq "catalog-api.env rendering is deterministic" "${cat1}" "${cat2}"
has() { grep -qxF -- "$2" <<<"$1"; }
expect_true "eventbus is an amqp URI with vhost" has "${common1}" 'ConnectionStrings__eventbus=amqp://eshop:mqPass3@127.0.0.1:5672/eshop'
expect_true "redis connection string"            has "${common1}" 'ConnectionStrings__redis=127.0.0.1:6379,password=redisPass2'
expect_true "ASPNETCORE_ENVIRONMENT=Production"  has "${common1}" 'ASPNETCORE_ENVIRONMENT=Production'
expect_true "forwarded headers enabled"          has "${common1}" 'ASPNETCORE_FORWARDEDHEADERS_ENABLED=true'
expect_true "health opt-in key"                  has "${common1}" 'ESHOP_EXPOSE_HEALTH_ENDPOINTS=true'
expect_true "service discovery contract (documented)" has "${common1}" '# Services__catalog-api__http__0=http://127.0.0.1:5222'
expect_true "ESHOP_CONFIG_ARGS carries catalog endpoint" grep -q -- '--Services:catalog-api:http:0=http://127.0.0.1:5222' <<<"${common1}"
expect_true "OTLP endpoint is optional/commented" has "${common1}" '#OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317'
expect_true "ASPNETCORE_URLS on loopback"        has "${cat1}" 'ASPNETCORE_URLS=http://127.0.0.1:5222'
expect_true "catalogdb Npgsql keyword string"    has "${cat1}" 'ConnectionStrings__catalogdb=Host=127.0.0.1;Port=5432;Database=catalogdb;Username=eshop;Password=pgPass1'
expect_false "no unresolved placeholders"        grep -qE '\$\{|@[A-Z_]+@' <<<"${common1}${cat1}"
# systemd EnvironmentFile rejects variable names with '-': no active (uncommented) key may contain one.
expect_false "no dashed variable names in active env lines" grep -qE '^[A-Za-z0-9_]*-[A-Za-z0-9_-]*=' <<<"${common1}${cat1}"

echo "render_template whitelist semantics"
printf 'a=${ALLOWED} b=${OTHER} c=$OTHER\n' > "${SCRATCH}/t.tmpl"
ALLOWED=yes OTHER=leak
export ALLOWED OTHER
expect_eq "only whitelisted variables are substituted" "$(render_template "${SCRATCH}/t.tmpl" ALLOWED)" 'a=yes b=${OTHER} c=$OTHER'
expect_false "unset whitelisted variable is an error" bash -c 'source "$1"; unset NOPE; render_template "$2" NOPE' _ "${DEPLOY_DIR}/lib/common.sh" "${SCRATCH}/t.tmpl"
printf 'x=@LEFT@\n' > "${SCRATCH}/u.tmpl"
expect_false "unresolved @TOKEN@ is an error" bash -c 'source "$1"; render_at_template "$2" A=b' _ "${DEPLOY_DIR}/lib/common.sh" "${SCRATCH}/u.tmpl"

echo "infrastructure constants"
expect_eq "loopback address" "${ESHOP_LOOPBACK_ADDR}" "127.0.0.1"
expect_eq "postgres port" "${ESHOP_PG_PORT}" "5432"
expect_eq "redis port" "${ESHOP_REDIS_PORT}" "6379"
expect_eq "amqp port" "${ESHOP_AMQP_PORT}" "5672"

echo "systemd units"
mkdir -p "${SCRATCH}/units"
UNIT="${SCRATCH}/units/eshop-catalog-api.service"
render_unit_template catalog-api > "${UNIT}"
expect_eq "catalog unit is rendered from the template (no explicit file)" "$(unit_source_for catalog-api)" "template"
for d in User=eshop Group=eshop NoNewPrivileges=true ProtectSystem=strict ProtectHome=true PrivateTmp=true \
         ProtectKernelTunables=true ProtectControlGroups=true RestrictSUIDSGID=true Restart=on-failure \
         EnvironmentFile=/etc/eshop/common.env EnvironmentFile=/etc/eshop/catalog-api.env \
         WorkingDirectory=/opt/eshop/catalog-api WantedBy=eshop.target ReadWritePaths=/var/lib/eshop; do
    expect_true "unit has ${d}" grep -qxF "${d}" "${UNIT}"
done
expect_true "unit ExecStart runs the real assembly" grep -qE '^ExecStart=/usr/bin/dotnet /opt/eshop/catalog-api/Catalog\.API\.dll( |$)' "${UNIT}"
expect_true "unit orders after postgresql, rabbitmq, redis" grep -qE '^After=.*postgresql\.service.*rabbitmq-server\.service.*redis-server\.service' "${UNIT}"
expect_true "unit has pg_isready readiness gate" grep -q 'pg_isready -q -h 127.0.0.1 -p 5432' "${UNIT}"
expect_true "target wants the catalog unit" grep -qxF 'Wants=eshop-catalog-api.service' "${DEPLOY_DIR}/systemd/eshop.target"
if command -v systemd-analyze >/dev/null 2>&1; then
    cp "${DEPLOY_DIR}/systemd/eshop.target" "${SCRATCH}/units/"
    out="$(cd "${SCRATCH}/units" && systemd-analyze verify ./eshop.target ./eshop-catalog-api.service 2>&1 || true)"
    # Only complain about syntax problems in our files; missing runtime binaries/users are expected in a scratch dir.
    if grep -E 'eshop-catalog-api.service|eshop.target' <<<"${out}" | grep -Eqi 'unknown (key|section|lvalue)|invalid|bad|failed to parse|ignoring'; then
        bad "systemd-analyze verify reports syntax problems: ${out}"
    else
        ok "systemd-analyze verify finds no unit syntax problems"
    fi
fi

echo "repository hygiene"
for f in "${DEPLOY_DIR}"/*.sh "${DEPLOY_DIR}"/lib/*.sh "${DEPLOY_DIR}"/tests/*.sh; do
    rel="${f#"${DEPLOY_DIR}"/}"
    [[ "$(head -n1 "${f}")" == '#!/usr/bin/env bash' ]] && ok "${rel}: shebang" || bad "${rel}: shebang"
    bash -n "${f}" 2>/dev/null && ok "${rel}: bash -n" || bad "${rel}: bash -n"
    case "${f}" in */lib/*) ;; *) [[ -x "${f}" ]] && ok "${rel}: executable" || bad "${rel}: executable" ;; esac
done
# Comments may say "no Docker"; only non-comment lines count.
if grep -rIhE '^[^#]*(docker|podman)' -i "${DEPLOY_DIR}"/provision-host.sh "${DEPLOY_DIR}"/publish.sh "${DEPLOY_DIR}"/lib "${DEPLOY_DIR}"/systemd "${DEPLOY_DIR}"/env >/dev/null; then
    bad "provisioning/publish/units/env must not reference docker or podman"
else
    ok "provisioning/publish/units/env do not use docker or podman"
fi
if grep -rInE '/(home|root|l2l|Users)/' "${DEPLOY_DIR}" --include='*.sh' --include='*.tmpl' --include='*.service' --include='*.target' | grep -v 'tests/test-lib.sh' | grep -v '^\S*:[0-9]*:\s*#' >/dev/null; then
    bad "unexpected absolute home/workspace path in deploy/ubuntu"
else
    ok "no workspace-specific absolute paths"
fi

echo
echo "Result: ${T_PASS} passed, ${T_FAIL} failed"
[[ "${T_FAIL}" -eq 0 ]]
