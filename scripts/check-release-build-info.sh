#!/usr/bin/env bash
# Fail closed unless BUILD-INFO carries the exact sanitizer attestation required
# for an official release. Local auto/skip TSan builds remain useful artifacts,
# but must never reach installer packing, tagging, or publication.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

if [ "$#" -lt 1 ]; then
    echo "usage: $0 BUILD-INFO [--version VERSION] [--runtime TARBALL] [--installer RUN] [--expected-kit DIR]" >&2
    exit 2
fi

info="$1"
shift
runtime=""
installer=""
expected_kit=""
expected_version=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || { echo "!! --version needs a value" >&2; exit 2; }
            expected_version="$2"; shift 2 ;;
        --runtime)
            [ "$#" -ge 2 ] || { echo "!! --runtime needs a path" >&2; exit 2; }
            runtime="$2"; shift 2 ;;
        --installer)
            [ "$#" -ge 2 ] || { echo "!! --installer needs a path" >&2; exit 2; }
            installer="$2"; shift 2 ;;
        --expected-kit)
            [ "$#" -ge 2 ] || { echo "!! --expected-kit needs a path" >&2; exit 2; }
            expected_kit="$2"; shift 2 ;;
        *) echo "!! unknown release-check option: $1" >&2; exit 2 ;;
    esac
done
official_record='pipeasio-sanitizers: ASan+UBSan unit+panel passed (driver imports verified); TSan unit passed'

[ -f "$info" ] && [ ! -L "$info" ] || {
    echo "!! release BUILD-INFO is missing: $info" >&2
    exit 1
}

if [ -n "$expected_version" ]; then
    [[ "$expected_version" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] || {
        echo "!! invalid expected release version: $expected_version" >&2
        exit 2
    }
    [ "$(grep -c '^dist-version:' "$info" || true)" -eq 1 ] \
        && grep -qxF "dist-version: $expected_version" "$info" || {
        echo "!! $info does not contain exactly dist-version: $expected_version" >&2
        exit 1
    }
fi

source_record_count="$(grep -c '^source-tree:' "$info" || true)"
source_record="$(sed -n 's/^source-tree: *//p' "$info")"
source_actual="$(bash "$root/scripts/source-tree-digest.sh")"
if [ "$source_record_count" -ne 1 ] \
   || [[ ! "$source_record" =~ ^[0-9a-f]{64}$ ]] \
   || [ "$source_record" != "$source_actual" ]; then
    echo "!! $info does not identify the current source candidate" >&2
    echo "!! recorded=${source_record:-missing} current=$source_actual" >&2
    exit 1
fi

record_count="$(grep -c -- '^pipeasio-sanitizers:' "$info" || true)"
if [ "$record_count" != 1 ] || ! grep -qxF -- "$official_record" "$info"; then
    echo "!! $info is not eligible for release" >&2
    echo "!! expected exactly one official sanitizer attestation:" >&2
    echo "   $official_record" >&2
    exit 1
fi
for helper_record in cabextract-static ableton-linkd; do
    helper_count="$(grep -c "^${helper_record}:" "$info" || true)"
    helper_hash="$(sed -n "s/^${helper_record}: *//p" "$info")"
    [ "$helper_count" -eq 1 ] && [[ "$helper_hash" =~ ^[0-9a-f]{64}$ ]] || {
        echo "!! $info has no unique $helper_record build hash" >&2
        exit 1
    }
done

# Packaging must attest the record carried by the runtime, not merely a
# neighbouring dist/ file. A stale official record beside an auto/skip build
# must not turn that non-release runtime into a publishable installer.
if [ -n "$runtime" ]; then
    [ -f "$runtime" ] && [ ! -L "$runtime" ] || {
        echo "!! release runtime is missing: $runtime" >&2
        exit 1
    }
    runtime_checksum="$runtime.sha256"
    [ -f "$runtime_checksum" ] && [ ! -L "$runtime_checksum" ] || {
        echo "!! release runtime checksum is missing: $runtime_checksum" >&2
        exit 1
    }
    [ "$(wc -l < "$runtime_checksum")" -eq 1 ] || {
        echo "!! release runtime checksum must contain exactly one record" >&2
        exit 1
    }
    read -r checksum_hash checksum_name checksum_extra < "$runtime_checksum"
    checksum_name="${checksum_name#\*}"
    [[ "$checksum_hash" =~ ^[0-9a-f]{64}$ ]] \
        && [ -z "$checksum_extra" ] \
        && [ "$checksum_name" = "$(basename "$runtime")" ] \
        && [ "$checksum_hash" = "$(sha256sum "$runtime" | awk '{print $1}')" ] || {
        echo "!! release runtime checksum does not bind $(basename "$runtime")" >&2
        exit 1
    }
    member='wine-d2d1-nspa-11.13/ABLETON-WINE-BUILD-INFO.txt'
    member_count="$(tar -I zstd -tf "$runtime" | awk -v member="$member" '$0 == member { ++count } END { print count + 0 }')"
    if [ "$member_count" != 1 ]; then
        echo "!! $runtime must contain exactly one $member" >&2
        exit 1
    fi
    scratch="$(mktemp -d /tmp/ableton-release-artifacts.XXXXXX)"
    cleanup_release_artifacts()
    {
        case "$scratch" in
            /tmp/ableton-release-artifacts.*) rm -rf -- "${scratch:?}" ;;
            *) echo "!! refusing to remove unexpected release-check path" >&2; return 1 ;;
        esac
    }
    trap cleanup_release_artifacts EXIT
    embedded="$scratch/embedded-build-info"
    tar --no-wildcards -I zstd -xOf "$runtime" "$member" > "$embedded"
    if ! cmp -s -- "$info" "$embedded"; then
        echo "!! $info does not byte-match the BUILD-INFO embedded in $runtime" >&2
        exit 1
    fi

    # Treat the installer as data. The verifier matches the entire transport
    # header to the trusted template, hashes the suffix, rejects unsafe archive
    # metadata, and compares the complete member set with the current kit.
    if [ -n "$installer" ]; then
        [ -n "$expected_version" ] || {
            echo "!! an installer check also requires --version" >&2
            exit 2
        }
        [ -f "$installer" ] && [ ! -L "$installer" ] || {
            echo "!! release installer is missing: $installer" >&2
            exit 1
        }
        verifier=(
            python3 "$root/scripts/verify-installer-payload.py"
            --root "$root"
            --installer "$installer"
            --version "$expected_version"
            --runtime "$runtime"
            --info "$info"
        )
        if [ -n "$expected_kit" ]; then
            [ -d "$expected_kit" ] && [ ! -L "$expected_kit" ] || {
                echo "!! trusted expected kit is missing: $expected_kit" >&2
                exit 1
            }
            verifier+=(--expected-kit "$expected_kit")
        fi
        "${verifier[@]}"
    fi
elif [ -n "$installer" ]; then
    echo "!! an installer check also requires its standalone runtime" >&2
    exit 2
fi
[ -z "$expected_kit" ] || [ -n "$installer" ] || {
    echo "!! --expected-kit also requires --installer" >&2
    exit 2
}
