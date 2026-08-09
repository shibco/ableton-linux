#!/usr/bin/env bash

download_https() {
    local url="$1"
    local destination="$2"

    case "$url" in
        https://*) ;;
        *)
            printf 'Refusing non-HTTPS installer URL: %s\n' "$url"
            return 64
            ;;
    esac

    if have curl; then
        local -a curl_args=(--fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 180)
        curl "${curl_args[@]}" --output "$destination" "$url"
    elif have wget; then
        local -a wget_args=(--quiet --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=2)
        wget "${wget_args[@]}" --output-document="$destination" "$url"
    else
        printf 'Neither curl nor wget is installed.\n'
        return 69
    fi
}

fetch_and_verify_installer() {
    local url="$1"
    local destination="$2"
    local expected="${3:-}"
    local checksum_file="$destination.sha256"
    local actual

    subsection "Download installer"
    printf 'URL: %s\n' "$url"
    if ! download_https "$url" "$destination"; then
        printf 'Installer download failed.\n'
        return 1
    fi

    if [[ ! -s "$destination" ]] || ! grep -Iq . "$destination"; then
        printf 'Downloaded installer is empty or not a text script.\n'
        return 1
    fi
    if [[ "$(head -n 1 "$destination")" != '#!'* ]]; then
        printf 'Downloaded installer does not start with a script interpreter line.\n'
        return 1
    fi

    actual="$(sha256sum "$destination" | awk '{print $1}')"
    printf 'Downloaded SHA-256: %s\n' "$actual"

    if [[ -z "$expected" ]]; then
        printf 'Looking for checksum: %s.sha256\n' "$url"
        if download_https "$url.sha256" "$checksum_file" 2>/dev/null; then
            expected="$(grep -Eio '[[:xdigit:]]{64}' "$checksum_file" | head -n 1 || true)"
        fi
    fi

    if [[ -z "$expected" ]]; then
        if [[ ${ALLOW_UNVERIFIED_INSTALLER:-0} == 1 ]]; then
            printf 'WARNING: no installer checksum was available; explicit override accepted.\n'
        else
            printf 'No trusted installer checksum was available.\n'
            printf 'Publish %s.sha256, pass --installer-sha256, or deliberately use --allow-unverified-installer.\n' "$url"
            return 1
        fi
    elif [[ "${expected,,}" != "${actual,,}" ]]; then
        printf 'Installer checksum mismatch. Expected %s, got %s.\n' "$expected" "$actual"
        return 1
    else
        printf 'Installer checksum verified.\n'
    fi

    chmod 700 "$destination"
    # Read by the sourcing script (run-session records it with the INSTALLER
    # result); nothing in this file reads it.
    # shellcheck disable=SC2034
    INSTALLER_ACTUAL_SHA256="$actual"
    return 0
}
