#!/usr/bin/env bash
# steps-dotnet.sh - .NET SDK/runtime that satisfies global.json.
#
# Strategy (see README ".NET SDK path"):
#   1. read the SDK pin from <repo>/global.json
#   2. if an installed SDK already satisfies it -> done
#   3. otherwise try apt (dotnet-sdk-10.0 from the Ubuntu 24.04 feeds) and re-check
#   4. still not satisfied (the distro feed usually ships an older feature band than
#      the repo pin) -> dotnet-install.sh pinned to the exact global.json version
#      into /usr/share/dotnet, plus the ASP.NET Core runtime, symlinked from
#      /usr/local/bin and /usr/bin
# shellcheck shell=bash
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ESHOP_DOTNET_APT_PACKAGE="${ESHOP_DOTNET_APT_PACKAGE:-dotnet-sdk-10.0}"
ESHOP_DOTNET_INSTALL_DIR="${ESHOP_DOTNET_INSTALL_DIR:-/usr/share/dotnet}"
ESHOP_DOTNET_INSTALL_URL="${ESHOP_DOTNET_INSTALL_URL:-https://dot.net/v1/dotnet-install.sh}"
ESHOP_GLOBAL_JSON="${ESHOP_GLOBAL_JSON:-${ESHOP_REPO_DIR}/global.json}"

# ---------------------------------------------------------------------------
# global.json parsing (plain sed, no jq/python dependency)
# ---------------------------------------------------------------------------
# _global_json_sdk_block FILE - the text of the "sdk": { ... } object.
_global_json_sdk_block() {
    sed -n '/"sdk"[[:space:]]*:/,/}/p' "$1"
}

# global_json_field FILE KEY - string/boolean value of KEY inside the "sdk" object.
global_json_field() {
    local file=$1 key=$2
    [[ -f "${file}" ]] || die "global.json not found: ${file}"
    _global_json_sdk_block "${file}" \
        | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}[:space:]]*\)\"\{0,1\}.*/\1/p" \
        | head -n1
}

global_json_sdk_version()      { global_json_field "$1" version; }
global_json_roll_forward()     { local r; r="$(global_json_field "$1" rollForward)"; printf '%s\n' "${r:-latestPatch}"; }
global_json_allow_prerelease() { local r; r="$(global_json_field "$1" allowPrerelease)"; printf '%s\n' "${r:-false}"; }

# ---------------------------------------------------------------------------
# SDK version arithmetic
# ---------------------------------------------------------------------------
# An SDK version is MAJOR.MINOR.NNN[-prerelease] where NNN = <feature band digit><2-digit patch>.
# e.g. 10.0.302 -> major 10, minor 0, feature band 3 (the "3xx" band), patch 02.
#
# sdk_version_parse VERSION - prints "MAJOR MINOR BAND PATCH PRERELEASE(0|1)"; non-zero if malformed.
sdk_version_parse() {
    local v=$1 core pre=0
    if [[ "${v}" == *-* ]]; then pre=1; fi
    core=${v%%-*}
    core=${core%%+*}
    if [[ ! "${core}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        return 1
    fi
    local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} third=${BASH_REMATCH[3]}
    local band=$((10#${third} / 100)) patch=$((10#${third} % 100))
    printf '%d %d %d %d %d\n' "$((10#${major}))" "$((10#${minor}))" "${band}" "${patch}" "${pre}"
}

# global_json_pin FILE - sets the caller's local req/policy/pre from the "sdk" object; dies if
# sdk.version is missing. Call it directly (not inside $(...)) so the assignments and die reach the caller.
global_json_pin() {
    req="$(global_json_sdk_version "$1")"
    [[ -n "${req}" ]] || die "could not read sdk.version from $1"
    policy="$(global_json_roll_forward "$1")"
    pre="$(global_json_allow_prerelease "$1")"
}

# dotnet_sdk_candidate_ok REQUIRED INSTALLED ROLLFORWARD ALLOWPRERELEASE
# Returns 0 if the single INSTALLED SDK version is acceptable for the global.json
# pin REQUIRED under the given rollForward policy. This mirrors the .NET SDK
# resolver, expressed as "does this installed SDK fall in the accepted set":
#   disable                    exactly REQUIRED
#   patch / latestPatch        same major.minor and feature band, patch >= required
#   feature / latestFeature    same major.minor, (band, patch) >= required   [repo default]
#   minor  / latestMinor       same major, (minor, band, patch) >= required
#   major  / latestMajor       anything >= required
# (The "latest*" variants only change WHICH accepted SDK is picked when several are
# installed, not whether one is acceptable.)
dotnet_sdk_candidate_ok() {
    local required=$1 installed=$2 policy=${3:-latestPatch} allow_pre=${4:-false}
    local r i
    r="$(sdk_version_parse "${required}")" || return 2
    i="$(sdk_version_parse "${installed}")" || return 1
    local rM rm rb rp rpre iM im ib ip ipre
    read -r rM rm rb rp rpre <<<"${r}"
    read -r iM im ib ip ipre <<<"${i}"

    if [[ "${ipre}" -eq 1 && "${allow_pre}" != "true" && "${rpre}" -eq 0 ]]; then
        return 1
    fi

    case "${policy}" in
        disable)
            [[ "${installed}" == "${required}" ]]
            ;;
        patch|latestPatch)
            [[ "${iM}" -eq "${rM}" && "${im}" -eq "${rm}" && "${ib}" -eq "${rb}" && "${ip}" -ge "${rp}" ]]
            ;;
        feature|latestFeature)
            [[ "${iM}" -eq "${rM}" && "${im}" -eq "${rm}" ]] || return 1
            [[ "${ib}" -gt "${rb}" || ( "${ib}" -eq "${rb}" && "${ip}" -ge "${rp}" ) ]]
            ;;
        minor|latestMinor)
            [[ "${iM}" -eq "${rM}" ]] || return 1
            _sdk_tuple_ge "${im}" "${ib}" "${ip}" "${rm}" "${rb}" "${rp}"
            ;;
        major|latestMajor)
            _sdk_tuple_ge "${iM}" "${im}" "${ib}" "${ip}" "${rM}" "${rm}" "${rb}" "${rp}"
            ;;
        *)
            log_error "unsupported rollForward policy in global.json: ${policy}"
            return 2
            ;;
    esac
}

# _sdk_tuple_ge A... B... - lexicographic >= over two equal-length integer tuples
# (arguments are the first tuple followed by the second tuple).
_sdk_tuple_ge() {
    local n=$(($# / 2)) idx
    local -a t=("$@")
    for ((idx = 0; idx < n; idx++)); do
        if [[ "${t[idx]}" -gt "${t[idx + n]}" ]]; then return 0; fi
        if [[ "${t[idx]}" -lt "${t[idx + n]}" ]]; then return 1; fi
    done
    return 0
}

# dotnet_sdk_satisfies REQUIRED ROLLFORWARD ALLOWPRERELEASE [INSTALLED...]
# Returns 0 if ANY of the INSTALLED SDK versions satisfies the pin. When no
# versions are passed, they are read from `dotnet --list-sdks`.
dotnet_sdk_satisfies() {
    local required=$1 policy=$2 allow_pre=$3; shift 3
    local -a installed=("$@")
    if [[ "${#installed[@]}" -eq 0 ]]; then
        mapfile -t installed < <(dotnet_list_sdk_versions)
    fi
    local v
    for v in "${installed[@]}"; do
        [[ -n "${v}" ]] || continue
        if dotnet_sdk_candidate_ok "${required}" "${v}" "${policy}" "${allow_pre}"; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Inspecting what is installed
# ---------------------------------------------------------------------------
# dotnet_host_path - the dotnet muxer to use: $DOTNET, then PATH, then known roots.
dotnet_host_path() {
    if [[ -n "${DOTNET:-}" && -x "${DOTNET}" ]]; then printf '%s\n' "${DOTNET}"; return 0; fi
    if command_exists dotnet; then command -v dotnet; return 0; fi
    local c
    for c in "${ESHOP_DOTNET_INSTALL_DIR}/dotnet" /usr/lib/dotnet/dotnet /usr/share/dotnet/dotnet; do
        if [[ -x "${c}" ]]; then printf '%s\n' "${c}"; return 0; fi
    done
    return 1
}

# dotnet_list_sdk_versions - installed SDK versions, one per line (empty if no dotnet).
dotnet_list_sdk_versions() {
    local d
    d="$(dotnet_host_path)" || return 0
    # Line format: "10.0.302 [/usr/share/dotnet/sdk]"
    "${d}" --list-sdks 2>/dev/null | awk 'NF{print $1}' || true
}

# dotnet_check_global_json [GLOBAL_JSON] [quiet] - 0 if the installed SDK satisfies the pin.
# Prints what was required and found (a failure is logged as info when "quiet").
# This is the ".NET toolchain consistency check" used by check-dotnet.sh/publish.sh.
dotnet_check_global_json() {
    local gj=${1:-${ESHOP_GLOBAL_JSON}} quiet=${2:-} req policy pre
    global_json_pin "${gj}"
    local -a have
    mapfile -t have < <(dotnet_list_sdk_versions)
    if dotnet_sdk_satisfies "${req}" "${policy}" "${pre}" "${have[@]}"; then
        log_ok ".NET SDK satisfies global.json (requires ${req}, rollForward=${policy}; installed: ${have[*]})"
        return 0
    fi
    if [[ "${quiet}" == "quiet" ]]; then
        log_info ".NET SDK does not (yet) satisfy global.json (requires ${req}, rollForward=${policy}; installed: ${have[*]:-none})"
    else
        log_error ".NET SDK does not satisfy global.json (requires ${req}, rollForward=${policy}; installed: ${have[*]:-none})"
    fi
    return 1
}

# dotnet_runtime_ok [DOTNET_BIN] - the host provides an ASP.NET Core 10 runtime.
dotnet_runtime_ok() {
    local d=${1:-/usr/bin/dotnet}
    [[ -x "${d}" ]] || return 1
    "${d}" --list-runtimes 2>/dev/null | grep -q '^Microsoft\.AspNetCore\.App 10\.'
}

# ---------------------------------------------------------------------------
# apt candidate pre-check
# ---------------------------------------------------------------------------
# apt_candidate_sdk_version PKG - upstream SDK version of the apt candidate
# (e.g. "10.0.100-0ubuntu1~24.04.1" -> "10.0.100"); empty if unavailable.
apt_candidate_sdk_version() {
    local cand
    cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
    [[ -n "${cand}" && "${cand}" != "(none)" ]] || return 0
    cand=${cand#*:}                       # drop epoch
    sed -n 's/^\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p' <<<"${cand}"
}

# ---------------------------------------------------------------------------
# dotnet-install.sh fallback
# ---------------------------------------------------------------------------
# dotnet_install_fallback VERSION [runtime-only]
# Installs the exact SDK VERSION (unless runtime-only) and the latest ASP.NET Core
# runtime of the same major.minor channel into ESHOP_DOTNET_INSTALL_DIR.
dotnet_install_fallback() {
    local version=$1 mode=${2:-sdk} dir=${ESHOP_DOTNET_INSTALL_DIR} tmp channel
    channel="$(sed -n 's/^\([0-9]\+\)\.\([0-9]\+\)\..*/\1.\2/p' <<<"${version}")"   # 10.0.302 -> 10.0
    [[ -n "${channel}" ]] || die "cannot derive a release channel from SDK version ${version}"
    require_cmd curl
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN
    log_info "downloading ${ESHOP_DOTNET_INSTALL_URL}"
    curl -fsSL "${ESHOP_DOTNET_INSTALL_URL}" -o "${tmp}/dotnet-install.sh"
    chmod 0700 "${tmp}/dotnet-install.sh"
    ensure_dir "${dir}" 0755 root:root

    # Native libraries the .NET host needs on a minimal image (ICU package name is release specific).
    local icu
    icu="$(apt-cache pkgnames libicu 2>/dev/null | grep -E '^libicu[0-9]+$' | sort -V | tail -n1 || true)"
    apt_install ca-certificates ${icu:+"${icu}"}

    if [[ "${mode}" != "runtime-only" ]]; then
        log_info "dotnet-install.sh: SDK ${version} -> ${dir}"
        "${tmp}/dotnet-install.sh" --version "${version}" --install-dir "${dir}" --no-path
    fi
    log_info "dotnet-install.sh: ASP.NET Core runtime (channel ${channel}) -> ${dir}"
    "${tmp}/dotnet-install.sh" --channel "${channel}" --runtime aspnetcore --install-dir "${dir}" --no-path
}

# dotnet_link_host ROOT - make `dotnet` resolve to ROOT/dotnet from /usr/local/bin
# and, because the systemd units run /usr/bin/dotnet, from /usr/bin as well.
dotnet_link_host() {
    local root=$1
    [[ -x "${root}/dotnet" ]] || die "no dotnet executable in ${root}"
    ln -sfn "${root}/dotnet" /usr/local/bin/dotnet
    local cur
    cur="$(readlink -f /usr/bin/dotnet 2>/dev/null || true)"
    if [[ ! -e /usr/bin/dotnet ]]; then
        ln -s "${root}/dotnet" /usr/bin/dotnet
        log_info "linked /usr/bin/dotnet -> ${root}/dotnet"
    elif [[ "${cur}" != "$(readlink -f "${root}/dotnet")" ]]; then
        log_warn "/usr/bin/dotnet currently resolves to ${cur}; repointing it to ${root}/dotnet because the systemd units run /usr/bin/dotnet and need the runtime pinned by global.json"
        ln -sfn "${root}/dotnet" /usr/bin/dotnet
    fi
}

# ---------------------------------------------------------------------------
# step
# ---------------------------------------------------------------------------
step_dotnet() {
    log_step ".NET SDK / runtime (global.json)"
    local gj=${ESHOP_GLOBAL_JSON} req policy pre
    global_json_pin "${gj}"
    log_info "global.json requires SDK ${req} (rollForward=${policy}, allowPrerelease=${pre})"

    if dotnet_check_global_json "${gj}" quiet; then
        log_ok "already installed; no .NET SDK installation needed"
    else
        # 1) apt, but only when the candidate could actually satisfy the pin
        local cand
        apt_update_once
        cand="$(apt_candidate_sdk_version "${ESHOP_DOTNET_APT_PACKAGE}")"
        if [[ -n "${cand}" ]] && ! dotnet_sdk_candidate_ok "${req}" "${cand}" "${policy}" "${pre}"; then
            log_warn "apt package ${ESHOP_DOTNET_APT_PACKAGE} offers SDK ${cand}, which does not satisfy global.json (${req}, ${policy}); skipping apt"
        else
            log_info "trying apt: ${ESHOP_DOTNET_APT_PACKAGE} (candidate: ${cand:-unknown})"
            apt_install "${ESHOP_DOTNET_APT_PACKAGE}" || log_warn "apt could not install ${ESHOP_DOTNET_APT_PACKAGE}"
        fi
        hash -r

        # 2) re-check, then fall back to dotnet-install.sh pinned to the global.json version
        if dotnet_check_global_json "${gj}" quiet; then
            log_ok "SDK satisfied via apt"
        else
            log_warn "apt did not provide an SDK satisfying global.json; falling back to dotnet-install.sh ${req}"
            dotnet_install_fallback "${req}"
            dotnet_link_host "${ESHOP_DOTNET_INSTALL_DIR}"
            hash -r
            dotnet_check_global_json "${gj}" || die ".NET SDK still does not satisfy global.json after dotnet-install.sh"
        fi
    fi

    # The systemd units run /usr/bin/dotnet, which therefore must offer the ASP.NET Core runtime.
    if dotnet_runtime_ok /usr/bin/dotnet; then
        log_ok "ASP.NET Core 10 runtime available via /usr/bin/dotnet"
    else
        local host
        host="$(dotnet_host_path)" || die "dotnet not found after installation"
        if ! dotnet_runtime_ok "${host}"; then
            apt_install aspnetcore-runtime-10.0 || log_warn "aspnetcore-runtime-10.0 unavailable via apt"
            host="$(dotnet_host_path)"
        fi
        if ! dotnet_runtime_ok "${host}"; then
            dotnet_install_fallback "${req}" runtime-only
            host="${ESHOP_DOTNET_INSTALL_DIR}/dotnet"
        fi
        dotnet_link_host "$(dirname "$(readlink -f "${host}")")"
        dotnet_runtime_ok /usr/bin/dotnet || die "no ASP.NET Core 10 runtime reachable through /usr/bin/dotnet"
    fi
}
