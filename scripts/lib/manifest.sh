#!/usr/bin/env bash
# File-level transaction and ownership manifest helpers for installer components.
# Paths containing newlines are rejected by config.sh; tab is rejected here so
# the on-disk records remain simple and auditable.

declare -Ag ABLETON_TXN_SEEN=()
declare -ag ABLETON_OWNED_PATHS=()
declare -Ag ABLETON_OWNED_KINDS=()
declare -Ag ABLETON_MANIFEST_TOUCHED=()
declare -Ag ABLETON_MANIFEST_DEOWNED=()

ableton_file_has_no_nul()
{
    local file="$1" count
    count="$(LC_ALL=C tr -cd '\000' < "$file" 2>/dev/null | wc -c)" || return 1
    [ "$count" -eq 0 ]
}

ableton_manifest_path_ok()
{
    case "$1" in *$'\n'*|*$'\r'*|*$'\t'*)
        ableton_config_error "managed path contains a newline or tab: $1"; return 1 ;;
    esac
}

# PR #182 (2026.08.08.1) briefly treated a configured custom Link binary as
# installer-owned. Recognize only that exact historical state for retirement.
ableton_pr182_custom_link_recorded()
{
    local path="$1" legacy_path="${ABLETON_PR182_CUSTOM_LINKD:-${ABLETON_LINKD:-}}"
    local expected_state config version launcher safe count manifest digest
    [ -n "$path" ] && [ "$path" = "$legacy_path" ] \
        && [ "$path" != "$ABLETON_DATA_HOME/ableton-linkd" ] || return 1
    expected_state="$(ableton_realpath_m "${XDG_STATE_HOME:-$HOME/.local/state}/ableton-wine")" || return 1
    [ "$ABLETON_STATE_HOME" = "$expected_state" ] \
        && ableton_state_marker_valid "$ABLETON_STATE_HOME" || return 1
    safe="$(ableton_path_is_safe_delete_target "$path")" || return 1
    [ "$safe" = "$path" ] || return 1
    case "$path" in "$HOME"/*) ;; *) return 1 ;; esac
    config="$ABLETON_CONFIG_FILE"
    [ -f "$config" ] && [ ! -L "$config" ] && [ -r "$config" ] \
        && ableton_file_has_no_nul "$config" \
        && ableton_managed_config_valid "$config" || return 1
    count="$(grep -c '^linkd=' "$config" 2>/dev/null || true)"
    [ "$count" -eq 1 ] && grep -qxF "linkd=$path" "$config" || return 1
    version="$ABLETON_DATA_HOME/VERSION"
    [ -f "$version" ] && [ ! -L "$version" ] \
        && cmp -s -- "$version" <(printf '2026.08.08.1\n') || return 1
    launcher="$ABLETON_BIN_HOME/ableton-live"
    [ -f "$launcher" ] && [ ! -L "$launcher" ] \
        && grep -qF 'Ableton Live launcher for the patched Wine stack' "$launcher" || return 1
    manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] \
        && ableton_file_has_no_nul "$manifest" || return 1
    count="$(awk -F '\t' -v p="$path" '$1=="file" && $2==p { n++ } END { print n+0 }' "$manifest")"
    [ "$count" -eq 1 ] || return 1
    digest="$(awk -F '\t' -v p="$path" '$1=="file" && $2==p { print $3 }' "$manifest")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
}

ableton_pr182_custom_link_owned()
{
    local path="$1" manifest digest current
    ableton_pr182_custom_link_recorded "$path" || return 1
    manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    digest="$(awk -F '\t' -v p="$path" '$1=="file" && $2==p { print $3 }' "$manifest")"
    current="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    [ "$current" = "$digest" ] || return 1
}

ableton_txn_pr182_custom_link_authorized()
{
    local path="$1" proof="${ABLETON_TRANSACTION_DIR:-}/pr182-custom-link"
    local meta config version launcher marker manifest object recorded_path digest current_digest count safe
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] && [ -d "$proof" ] && [ ! -L "$proof" ] || return 1
    [ "$(find "$proof" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" \
        = $'config\nlauncher\nmanifest\nmetadata\nobject\nstate-marker\nversion' ] || return 1
    meta="$proof/metadata"; config="$proof/config"; version="$proof/version"
    launcher="$proof/launcher"; marker="$proof/state-marker"; manifest="$proof/manifest"
    object="$proof/object"
    for recorded_path in "$meta" "$config" "$version" "$launcher" "$marker" "$manifest"; do
        [ -f "$recorded_path" ] && [ ! -L "$recorded_path" ] && [ -r "$recorded_path" ] \
            && ableton_file_has_no_nul "$recorded_path" || return 1
    done
    { [ -f "$object" ] || [ -L "$object" ]; } \
        && [ -n "$(ableton_manifest_digest "$object" 2>/dev/null || true)" ] || return 1
    [ "$(wc -l < "$meta")" -eq 4 ] || return 1
    [ "$(sed -n '1p' "$meta")" = format=1 ] || return 1
    recorded_path="$(sed -n '2s/^path=//p' "$meta")"
    digest="$(sed -n '3s/^recorded_digest=//p' "$meta")"
    current_digest="$(sed -n '4s/^current_digest=//p' "$meta")"
    [ "$recorded_path" = "$path" ] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
        && [[ "$current_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    safe="$(ableton_path_is_safe_delete_target "$path")" || return 1
    [ "$safe" = "$path" ] || return 1
    case "$path" in "$HOME"/*) ;; *) return 1 ;; esac
    ableton_managed_config_valid "$config" \
        && [ "$(grep -c '^linkd=' "$config")" -eq 1 ] \
        && grep -qxF "linkd=$path" "$config" || return 1
    cmp -s -- "$version" <(printf '2026.08.08.1\n') || return 1
    grep -qF 'Ableton Live launcher for the patched Wine stack' "$launcher" || return 1
    cmp -s -- "$marker" <(printf 'format=1\nowner=ableton-linux\n') || return 1
    [ "$(ableton_manifest_digest "$object")" = "$current_digest" ] || return 1
    count="$(awk -F '\t' -v p="$path" -v d="$digest" \
        '$1=="file" && $2==p && $3==d && NF==3 { n++ } END { print n+0 }' "$manifest")"
    [ "$count" -eq 1 ]
}

ableton_txn_authorize_pr182_custom_link()
{
    local path="$1" proof="$ABLETON_TRANSACTION_DIR/pr182-custom-link" tmp digest current_digest
    ableton_pr182_custom_link_recorded "$path" || return 1
    if [ -e "$proof" ] || [ -L "$proof" ]; then
        ableton_txn_pr182_custom_link_authorized "$path"
        return
    fi
    digest="$(awk -F '\t' -v p="$path" '$1=="file" && $2==p { print $3 }' \
        "$ABLETON_STATE_HOME/install-manifest.tsv")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_digest="$(ableton_manifest_digest "$path")" || return 1
    tmp="$(mktemp -d "$ABLETON_TRANSACTION_DIR/.pr182-custom-link.XXXXXX")" || return 1
    if ! printf 'format=1\npath=%s\nrecorded_digest=%s\ncurrent_digest=%s\n' \
            "$path" "$digest" "$current_digest" > "$tmp/metadata" \
       || ! cp -- "$ABLETON_CONFIG_FILE" "$tmp/config" \
       || ! cp -- "$ABLETON_DATA_HOME/VERSION" "$tmp/version" \
       || ! cp -- "$ABLETON_BIN_HOME/ableton-live" "$tmp/launcher" \
       || ! cp -- "$ABLETON_STATE_HOME/.ableton-linux-state" "$tmp/state-marker" \
       || ! cp -- "$ABLETON_STATE_HOME/install-manifest.tsv" "$tmp/manifest" \
       || ! cp -a -- "$path" "$tmp/object" \
       || ! chmod 600 "$tmp/metadata" "$tmp/config" "$tmp/version" \
            "$tmp/launcher" "$tmp/state-marker" "$tmp/manifest" \
       || ! { [ -L "$tmp/object" ] || chmod 600 "$tmp/object"; } \
       || ! mv -T -n -- "$tmp" "$proof" \
       || [ -e "$tmp" ] \
       || ! ableton_txn_pr182_custom_link_authorized "$path"; then
        rm -rf -- "$tmp"
        ableton_config_error "could not seal the historical custom Link ownership proof"
        return 1
    fi
}

ableton_managed_path_allowed()
{
    local kind="$1" path="$2" data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    case "$kind" in file|config|symlink) ;; *) return 1 ;; esac
    case "$path" in
        "$ABLETON_DATA_HOME/lib/config.sh"|"$ABLETON_DATA_HOME/lib/lifecycle.sh"|\
        "$ABLETON_DATA_HOME/lib/live-components.sh"|"$ABLETON_DATA_HOME/lib/manifest.sh"|\
        "$ABLETON_DATA_HOME/lib/pipeasio.sh"|\
        "$ABLETON_DATA_HOME/detect-scale.sh"|"$ABLETON_DATA_HOME/detect-theme.sh"|\
        "$ABLETON_DATA_HOME/shortcut-hold.sh"|"$ABLETON_DATA_HOME/setup-realtime.sh"|\
        "$ABLETON_DATA_HOME/audio-report.sh"|"$ABLETON_DATA_HOME/rollback.sh"|\
        "$ABLETON_DATA_HOME/pipewire-version-probe"|"$ABLETON_DATA_HOME/setsyscolors.exe"|\
        "$ABLETON_DATA_HOME/learnheal.exe"|"$ABLETON_DATA_HOME/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$ABLETON_DATA_HOME/$ABLETON_AUZ_DESKTOP_ID"|\
        "$ABLETON_DATA_HOME/wine-protocol-ableton.desktop"|\
        "$ABLETON_DATA_HOME/wine-extension-auz.desktop"|"$ABLETON_DATA_HOME/ableton-linkctl"|\
        "$ABLETON_DATA_HOME/setup-link.sh"|"$ABLETON_DATA_HOME/ableton-linkd.service"|\
        "$ABLETON_DATA_HOME/VERSION"|"$ABLETON_DATA_HOME/ableton-linkd"|\
        "$ABLETON_BIN_HOME/ableton-live"|"$ABLETON_BIN_HOME/max9"|\
        "$ABLETON_BIN_HOME/pipeasio-settings"|\
        "$data_root/applications/ableton-live.desktop"|\
        "$data_root/applications/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$data_root/applications/$ABLETON_AUZ_DESKTOP_ID"|\
        "$data_root/applications/wine-protocol-ableton.desktop"|\
        "$data_root/applications/wine-extension-auz.desktop"|\
        "$data_root/applications/max9.desktop"|\
        "$data_root/applications/wine-protocol-c74max.desktop"|\
        "$data_root/applications/pipeasio-settings.desktop"|\
        "$data_root/icons/hicolor/scalable/apps/live-beta.svg"|\
        "$data_root/icons/hicolor/scalable/apps/live-intro.svg"|\
        "$data_root/icons/hicolor/scalable/apps/live-lite.svg"|\
        "$data_root/icons/hicolor/scalable/apps/live-standard.svg"|\
        "$data_root/icons/hicolor/scalable/apps/live-suite.svg"|\
        "$data_root/icons/hicolor/scalable/apps/pipeasio.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-clip.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-device-group.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-device-preset.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-generic.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-max-device.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-meta-sound.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-pack.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-sample-analysis.svg"|\
        "$data_root/icons/hicolor/scalable/mimetypes/application-x-ableton-live-set.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-symbolic.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-beta-symbolic.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-intro-symbolic.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-lite-symbolic.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-standard-symbolic.svg"|\
        "$data_root/icons/hicolor/symbolic/apps/live-suite-symbolic.svg"|\
        "$data_root/mime/packages/x-wine-extension-auz.xml"|\
        "$data_root/mime/packages/application-ableton-live.xml"|\
        "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini") return 0 ;;
        *) [ "$kind" = file ] \
            && { ableton_pr182_custom_link_recorded "$path" \
                 || ableton_txn_pr182_custom_link_authorized "$path"; } ;;
    esac
}

# Transaction journals are executable restoration instructions, not ownership
# manifests.  Authorize only the exact project/configuration paths that a real
# installer operation snapshots.  In particular, a caller-supplied transaction
# directory must never make an arbitrary absolute path writable during rollback.
ableton_txn_target_allowed()
{
    local status="$1" path="$2" backup="$3"
    local config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    local data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    local runtime_parent runtime_base candidate relative root parent_real root_real desktop_dir=""

    if ableton_managed_path_allowed file "$path" \
       || ableton_managed_path_allowed config "$path" \
       || ableton_managed_path_allowed symlink "$path"; then
        return 0
    fi
    case "$path" in
        "$ABLETON_CONFIG_FILE"|\
        "$config_root/mimeapps.list"|\
        "$ABLETON_STATE_HOME/install-manifest.tsv"|\
        "$ABLETON_STATE_HOME/install-prestate.tsv"|\
        "$ABLETON_STATE_HOME/mime-prestate.tsv"|\
        "$ABLETON_STATE_HOME/link-firewall"|\
        "$ABLETON_WINE_ROOT/.ableton-linux-runtime"|\
        "$ABLETON_WINEPREFIX/.ableton-linux-prefix") return 0 ;;
        "$ABLETON_STATE_HOME/install-prestate/"*)
            relative="${path#"$ABLETON_STATE_HOME/install-prestate/"}"
            [[ "$relative" =~ ^[0-9a-f]{64}$ ]] || return 1
            parent_real="$(ableton_realpath_m "$(dirname "$path")")" || return 1
            root_real="$(ableton_realpath_m "$ABLETON_STATE_HOME/install-prestate")" || return 1
            if [ "$parent_real" = "$root_real" ]; then
                return 0
            fi
            return 1 ;;
    esac

    # User-facing rollback writes only these three metadata members inside a
    # marked reverse-runtime sibling.  The runtime marker binds the dynamic
    # timestamped directory to this installation before it becomes writable.
    runtime_parent="$(dirname "$ABLETON_WINE_ROOT")"
    runtime_base="$(basename "$ABLETON_WINE_ROOT")"
    case "$path" in
        "$runtime_parent/$runtime_base-rollback-"*/.ableton-linux-rollback/installer-config|\
        "$runtime_parent/$runtime_base-rollback-"*/.ableton-linux-rollback/pipeasio-config.ini|\
        "$runtime_parent/$runtime_base-rollback-"*/.ableton-linux-rollback/metadata)
            candidate="${path%/.ableton-linux-rollback/*}"
            if [ -d "$candidate" ] && [ ! -L "$candidate" ] \
               && ableton_runtime_marker_valid "$candidate" "$ABLETON_RUNTIME_NAME"; then
                return 0
            fi
            return 1 ;;
    esac

    # Wine's menu builder may leave prefix-specific desktop files under the
    # configured applications/Desktop roots.  Setup snapshots only regular
    # files containing this exact prefix token before deleting them.  Recheck
    # the same evidence in the position-bound backup during rollback.
    [ "$status" = present ] && [ -f "$backup" ] && [ ! -L "$backup" ] \
        && grep -qF "WINEPREFIX=\"$ABLETON_WINEPREFIX\"" "$backup" || return 1
    if [ -n "${XDG_DESKTOP_DIR:-}" ]; then
        desktop_dir="$XDG_DESKTOP_DIR"
    elif command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    for root in "$data_root/applications" "$desktop_dir"; do
        [ -n "$root" ] || continue
        case "$path" in "$root"/*.desktop) ;; *) continue ;; esac
        relative="${path#"$root"/}"
        # setup-prefix uses find -maxdepth 3; match that exact depth and refuse
        # an intermediate symlink that would escape the configured root.
        [ "$(awk -F/ '{print NF}' <<< "$relative")" -le 3 ] || return 1
        parent_real="$(ableton_realpath_m "$(dirname "$path")")" || return 1
        root_real="$(ableton_realpath_m "$root")" || return 1
        case "$parent_real" in "$root_real"|"$root_real"/*) return 0 ;; esac
        return 1
    done
    return 1
}

# A transaction that observed a concurrent replacement must never fall back to
# digest-only rollback/commit checks: another object can have identical bytes.
# Publish a durable fail-closed marker so every later transaction preflight
# refuses until a person inspects the retained transaction.
ableton_txn_mark_concurrent_conflict()
{
    local path="$1" marker="${ABLETON_TRANSACTION_DIR:-}/concurrent-conflict" tmp
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 1
    ableton_manifest_path_ok "$path" || return 1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ]
        return
    fi
    tmp="$(mktemp "$ABLETON_TRANSACTION_DIR/.concurrent-conflict.XXXXXX")" || return 1
    if ! printf 'format=1\npath=%s\n' "$path" > "$tmp" \
       || ! chmod 600 "$tmp" \
       || ! mv -T -n -- "$tmp" "$marker" \
       || [ -e "$tmp" ] \
       || [ ! -f "$marker" ] || [ -L "$marker" ]; then
        rm -f -- "$tmp"
        return 1
    fi
}

ableton_txn_validate_files()
{
    local txn="$1" journal="$1/files.tsv" status path backup post extra index=0 expected digest
    local -A seen=()
    [ -d "$txn" ] && [ ! -L "$txn" ] || {
        ableton_config_error "transaction directory is missing or unsafe"
        return 1
    }
    if [ -e "$txn/concurrent-conflict" ] || [ -L "$txn/concurrent-conflict" ]; then
        ableton_config_error "file transaction has a recorded concurrent-object conflict"
        return 1
    fi
    if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then return 0; fi
    if ! { [ -f "$journal" ] && [ ! -L "$journal" ] && [ -r "$journal" ] \
           && ableton_file_has_no_nul "$journal"; }; then
        ableton_config_error "file transaction journal is unsafe or contains binary data"
        return 1
    fi
    while IFS=$'\t' read -r status path backup post extra \
          || [ -n "$status$path$backup$post$extra" ]; do
        if [ -n "$extra" ] || [ -z "$path" ] \
           || ! ableton_manifest_path_ok "$path" \
           || [ -n "${seen[$path]+x}" ]; then
            ableton_config_error "invalid or duplicate file transaction row $index"
            return 1
        fi
        seen["$path"]=1
        case "$status" in
            absent)
                [ "$backup" = - ] || {
                    ableton_config_error "invalid absent file transaction row $index"
                    return 1
                } ;;
            present)
                expected="$txn/files/$index"
                if [ "$backup" != "$expected" ] \
                   || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                    ableton_config_error "invalid present file transaction row $index"
                    return 1
                fi
                digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
                [ -n "$digest" ] || {
                    ableton_config_error "unreadable file transaction backup $index"
                    return 1
                    } ;;
            *)
                ableton_config_error "unknown file transaction status in row $index"
                return 1 ;;
        esac
        post="${post:-pending}"
        case "$post" in
            pending|absent) ;;
            file:*|symlink:*) [[ "${post#*:}" =~ ^[0-9a-f]{64}$ ]] || {
                ableton_config_error "invalid post-operation token in file transaction row $index"
                return 1
            } ;;
            *) ableton_config_error "invalid post-operation token in file transaction row $index"; return 1 ;;
        esac
        ableton_txn_target_allowed "$status" "$path" "$backup" || {
            ableton_config_error "file transaction target is outside the allowed lifecycle scope: $path"
            return 1
        }
        index=$((index + 1))
    done < "$journal"
    return 0
}

ableton_txn_preflight_rollback_files()
{
    local txn="$1" status path backup post extra original current
    ableton_txn_validate_files "$txn" || return 1
    [ -e "$txn/files.tsv" ] || return 0
    while IFS=$'\t' read -r status path backup post extra \
          || [ -n "$status$path$backup$post$extra" ]; do
        post="${post:-pending}"
        if [ -e "$path" ] || [ -L "$path" ]; then
            { [ -f "$path" ] || [ -L "$path" ]; } && [ ! -d "$path" ] || {
                ableton_config_error "file rollback destination is unsafe: $path"
                return 1
            }
        fi
        current="$(ableton_object_token "$path" 2>/dev/null || true)"
        if [ "$status" = present ]; then
            original="$(ableton_object_token "$backup" 2>/dev/null || true)"
        else
            original=absent
        fi
        if [ -z "$current" ] \
           || { [ "$current" != "$original" ] \
                && { [ "$post" = pending ] || [ "$current" != "$post" ]; }; }; then
            ableton_config_error "file rollback destination changed while the transaction was open: $path"
            return 1
        fi
    done < "$txn/files.tsv"
}

ableton_txn_preflight_commit_files()
{
    local txn="$1" status path backup post extra current
    ableton_txn_validate_files "$txn" || return 1
    [ -e "$txn/files.tsv" ] || return 0
    while IFS=$'\t' read -r status path backup post extra \
          || [ -n "$status$path$backup$post$extra" ]; do
        [ "${post:-pending}" != pending ] || {
            ableton_config_error "file transaction has an unfinished mutation: $path"
            return 1
        }
        current="$(ableton_object_token "$path" 2>/dev/null || true)"
        [ "$current" = "$post" ] || {
            ableton_config_error "file transaction destination no longer matches its committed object: $path"
            return 1
        }
    done < "$txn/files.tsv"
}

ableton_txn_init()
{
    local files active journal
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 0
    [ -d "$ABLETON_TRANSACTION_DIR" ] && [ ! -L "$ABLETON_TRANSACTION_DIR" ] || {
        ableton_config_error "transaction directory is missing or unsafe"
        return 1
    }
    files="$ABLETON_TRANSACTION_DIR/files"
    active="$ABLETON_TRANSACTION_DIR/active"
    journal="$ABLETON_TRANSACTION_DIR/files.tsv"
    if [ -e "$files" ] || [ -L "$files" ]; then
        [ -d "$files" ] && [ ! -L "$files" ] || {
            ableton_config_error "transaction backup directory is unsafe"
            return 1
        }
    fi
    if [ -e "$active" ] || [ -L "$active" ]; then
        [ -f "$active" ] && [ ! -L "$active" ] || {
            ableton_config_error "transaction active marker is unsafe"
            return 1
        }
    fi
    if [ -e "$journal" ] || [ -L "$journal" ]; then
        if ! { [ -f "$journal" ] \
               && [ ! -L "$journal" ] \
               && [ -r "$journal" ] \
               && ableton_file_has_no_nul "$journal"; }; then
            ableton_config_error "file transaction journal is unsafe or unreadable"
            return 1
        fi
        ableton_txn_validate_files "$ABLETON_TRANSACTION_DIR" || return 1
    fi
    mkdir -p -- "$files" || return 1
    if [ ! -e "$active" ]; then : > "$active" || return 1; fi
    if [ ! -e "$journal" ]; then : > "$journal" || return 1; fi
}

ableton_txn_snapshot()
{
    local path="$1" id backup existing journal_tmp status backup_created=0
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 0
    ableton_manifest_path_ok "$path" || return 1
    if ! { [ -f "$ABLETON_TRANSACTION_DIR/files.tsv" ] \
           && [ ! -L "$ABLETON_TRANSACTION_DIR/files.tsv" ] \
           && [ -r "$ABLETON_TRANSACTION_DIR/files.tsv" ] \
           && ableton_file_has_no_nul "$ABLETON_TRANSACTION_DIR/files.tsv"; }; then
        ableton_config_error "file transaction journal is unsafe or unreadable"
        return 1
    fi
    ableton_txn_validate_files "$ABLETON_TRANSACTION_DIR" || return 1
    if [ -d "$path" ] && [ ! -L "$path" ]; then
        ableton_config_error "refusing to snapshot a directory as a managed file: $path"
        return 1
    fi
    [ -z "${ABLETON_TXN_SEEN[$path]+x}" ] || return 0
    existing="$(awk -F '\t' -v p="$path" '$2==p { n++ } END { print n+0 }' \
        "$ABLETON_TRANSACTION_DIR/files.tsv")" || return 1
    if [ "$existing" -eq 1 ]; then
        ABLETON_TXN_SEEN["$path"]=1
        return 0
    fi
    ABLETON_TXN_SEEN["$path"]=1
    id="$(wc -l < "$ABLETON_TRANSACTION_DIR/files.tsv")"
    backup="$ABLETON_TRANSACTION_DIR/files/$id"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        unset 'ABLETON_TXN_SEEN[$path]'
        ableton_config_error "transaction backup slot is already occupied: $backup"
        return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        if ! ableton_atomic_restore_object "$path" "$backup"; then
            unset 'ABLETON_TXN_SEEN[$path]'
            return 1
        fi
        backup_created=1
        status=present
    else
        status=absent
        backup=-
    fi
    journal_tmp="$(mktemp "$ABLETON_TRANSACTION_DIR/.files.tsv.XXXXXX")" || {
        [ "$backup_created" -eq 0 ] || rm -f -- "$backup"
        unset 'ABLETON_TXN_SEEN[$path]'
        return 1
    }
    if ! cp -- "$ABLETON_TRANSACTION_DIR/files.tsv" "$journal_tmp" \
       || ! printf '%s\t%s\t%s\tpending\n' "$status" "$path" "$backup" >> "$journal_tmp" \
       || ! chmod 600 "$journal_tmp" \
       || ! mv -f -- "$journal_tmp" "$ABLETON_TRANSACTION_DIR/files.tsv"; then
        rm -f -- "$journal_tmp"
        [ "$backup_created" -eq 0 ] || rm -f -- "$backup"
        unset 'ABLETON_TXN_SEEN[$path]'
        return 1
    fi
}

# Record an object that has already been atomically moved out of its live path.
# This closes the check/remove gap for the one historical external path that
# PR #182 briefly owned: the journal backup is copied from the exact claimed
# object, while the live destination remains absent until its disposition is
# decided.
ableton_txn_snapshot_captured()
{
    local path="$1" captured="$2" id backup journal_tmp existing
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 1
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    { [ -f "$captured" ] || [ -L "$captured" ]; } \
        && [ -n "$(ableton_manifest_digest "$captured" 2>/dev/null || true)" ] || return 1
    ableton_txn_init || return 1
    existing="$(awk -F '\t' -v p="$path" '$2==p { n++ } END { print n+0 }' \
        "$ABLETON_TRANSACTION_DIR/files.tsv")" || return 1
    [ "$existing" -eq 0 ] || {
        ableton_config_error "captured transaction path was already journaled: $path"
        return 1
    }
    id="$(awk 'END { print NR+0 }' "$ABLETON_TRANSACTION_DIR/files.tsv")" || return 1
    backup="$ABLETON_TRANSACTION_DIR/files/$id"
    [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
        ableton_config_error "transaction backup slot is already occupied: $backup"
        return 1
    }
    ableton_atomic_restore_object "$captured" "$backup" || return 1
    ableton_txn_target_allowed present "$path" "$backup" || {
        rm -f -- "$backup"
        ableton_config_error "captured transaction target is outside the allowed lifecycle scope: $path"
        return 1
    }
    journal_tmp="$(mktemp "$ABLETON_TRANSACTION_DIR/.files.tsv.XXXXXX")" || {
        rm -f -- "$backup"
        return 1
    }
    if ! cp -- "$ABLETON_TRANSACTION_DIR/files.tsv" "$journal_tmp" \
       || ! printf 'present\t%s\t%s\tabsent\n' "$path" "$backup" >> "$journal_tmp" \
       || ! chmod 600 "$journal_tmp" \
       || ! mv -f -- "$journal_tmp" "$ABLETON_TRANSACTION_DIR/files.tsv"; then
        rm -f -- "$journal_tmp" "$backup"
        return 1
    fi
    ABLETON_TXN_SEEN["$path"]=1
}

ableton_txn_expect()
{
    local path="$1" post="$2" journal tmp status p backup old extra matches=0
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 0
    case "$post" in
        absent) ;;
        file:*|symlink:*) [[ "${post#*:}" =~ ^[0-9a-f]{64}$ ]] || return 1 ;;
        *) ableton_config_error "invalid expected transaction object for $path"; return 1 ;;
    esac
    journal="$ABLETON_TRANSACTION_DIR/files.tsv"
    ableton_txn_validate_files "$ABLETON_TRANSACTION_DIR" || return 1
    tmp="$(mktemp "$ABLETON_TRANSACTION_DIR/.files.tsv.XXXXXX")" || return 1
    while IFS=$'\t' read -r status p backup old extra \
          || [ -n "$status$p$backup$old$extra" ]; do
        if [ "$p" = "$path" ]; then
            matches=$((matches + 1))
            printf '%s\t%s\t%s\t%s\n' "$status" "$p" "$backup" "$post" >> "$tmp"
        else
            printf '%s\t%s\t%s\t%s\n' "$status" "$p" "$backup" "${old:-pending}" >> "$tmp"
        fi
    done < "$journal"
    if [ "$matches" -ne 1 ] || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$journal"; then
        rm -f -- "$tmp"
        ableton_config_error "could not bind transaction state for $path"
        return 1
    fi
}

ableton_record_owned()
{
    local path="$1" kind="${2:-file}"
    ableton_manifest_path_ok "$path" || return 1
    ableton_managed_path_allowed "$kind" "$path" || {
        ableton_config_error "refusing to claim a path outside the managed integration set: $path"
        return 1
    }
    ABLETON_OWNED_PATHS+=("$path")
    ABLETON_OWNED_KINDS["$path"]="$kind"
    ABLETON_MANIFEST_TOUCHED["$path"]=1
    unset 'ABLETON_MANIFEST_DEOWNED[$path]'
}

# A de-owned path is deliberately omitted from the next manifest even if an
# older invocation recorded it.  This is used when an optional component goes
# away, and when a user replaces a managed path with their own file or link.
ableton_record_deowned()
{
    local path="$1"
    ableton_manifest_path_ok "$path" || return 1
    if ! ableton_managed_path_allowed file "$path" \
       && ! ableton_managed_path_allowed config "$path" \
       && ! ableton_managed_path_allowed symlink "$path"; then
        ableton_config_error "refusing to de-own a path outside the managed integration set: $path"
        return 1
    fi
    ABLETON_MANIFEST_TOUCHED["$path"]=1
    ABLETON_MANIFEST_DEOWNED["$path"]=1
    unset 'ABLETON_OWNED_KINDS[$path]'
}

# Regular files are hashed by content.  Symlinks are hashed as symlinks, using
# the literal link text rather than the referent, so retargeting a command is a
# detectable user modification even when both targets have identical bytes.
ableton_manifest_digest()
{
    local path="$1"
    if [ -L "$path" ]; then
        { printf 'symlink\0'; readlink -n -- "$path"; } | sha256sum | awk '{print $1}'
    elif [ -f "$path" ]; then
        sha256sum -- "$path" | awk '{print $1}'
    else
        return 1
    fi
}

ableton_object_token()
{
    local path="$1" digest
    if [ -L "$path" ]; then
        digest="$(ableton_manifest_digest "$path")" || return 1
        printf 'symlink:%s\n' "$digest"
    elif [ -f "$path" ]; then
        digest="$(ableton_manifest_digest "$path")" || return 1
        printf 'file:%s\n' "$digest"
    elif [ ! -e "$path" ]; then
        printf '%s\n' absent
    else
        return 1
    fi
}

ableton_regular_source_token()
{
    local digest
    [ -f "$1" ] || return 1
    digest="$(sha256sum -- "$1" | awk '{print $1}')" || return 1
    printf 'file:%s\n' "$digest"
}

ableton_symlink_text_token()
{
    local digest
    digest="$({ printf 'symlink\0'; printf '%s' "$1"; } | sha256sum | awk '{print $1}')" || return 1
    printf 'symlink:%s\n' "$digest"
}

ableton_atomic_restore_object()
{
    local source="$1" target="$2" expected tmp parent
    { [ -f "$source" ] || [ -L "$source" ]; } || return 1
    [ ! -d "$target" ] || [ -L "$target" ] || return 1
    expected="$(ableton_object_token "$source")" || return 1
    parent="$(dirname "$target")"
    mkdir -p -- "$parent" || return 1
    tmp="$(mktemp "$parent/.ableton-restore.XXXXXX")" || return 1
    rm -f -- "$tmp" || return 1
    if ! cp -a -- "$source" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$expected" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

ableton_txn_replace_unowned_file()
{
    local source="$1" target="$2" post
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    ableton_txn_snapshot "$target" || return 1
    post="$(ableton_object_token "$source")" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    ableton_atomic_restore_object "$source" "$target"
}

ableton_validate_ownership_manifest()
{
    local manifest="${1:-$ABLETON_STATE_HOME/install-manifest.tsv}"
    local kind path detail extra
    local -A seen=()
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then return 0; fi
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || {
        ableton_config_error "ownership manifest is unsafe or unreadable: $manifest"
        return 1
    }
    ableton_file_has_no_nul "$manifest" || {
        ableton_config_error "ownership manifest contains invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r kind path detail extra || [ -n "$kind$path$detail$extra" ]; do
        if [ -n "$extra" ] || [ -z "$path" ] || ! ableton_manifest_path_ok "$path" \
           || [ -n "${seen[$path]+x}" ]; then
            ableton_config_error "ownership manifest is invalid or ambiguous"
            return 1
        fi
        seen["$path"]=1
        case "$kind" in
            file|config|symlink)
                ableton_managed_path_allowed "$kind" "$path" || {
                    ableton_config_error "ownership manifest path is outside the managed integration set: $path"
                    return 1
                }
                [[ "$detail" =~ ^[0-9a-f]{64}$ ]] || {
                    ableton_config_error "ownership manifest has an invalid digest for $path"
                    return 1
                } ;;
            runtime)
                [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
                    ableton_config_error "ownership manifest has an invalid runtime record"
                    return 1
                } ;;
            *)
                ableton_config_error "ownership manifest has an unknown record kind"
                return 1 ;;
        esac
    done < "$manifest"
    return 0
}

ableton_validate_prestate_index()
{
    local index="${1:-$ABLETON_STATE_HOME/install-prestate.tsv}"
    local status path backup extra expected digest
    local -A seen=()
    if [ ! -e "$index" ] && [ ! -L "$index" ]; then return 0; fi
    [ -f "$index" ] && [ ! -L "$index" ] && [ -r "$index" ] || {
        ableton_config_error "pre-install state index is unsafe or unreadable: $index"
        return 1
    }
    ableton_file_has_no_nul "$index" || {
        ableton_config_error "pre-install state contains invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r status path backup extra || [ -n "$status$path$backup$extra" ]; do
        if [ -n "$extra" ] || [ "$status" != present ] || [ -z "$path" ] \
           || ! ableton_manifest_path_ok "$path" \
           || { ! ableton_managed_path_allowed file "$path" \
                && ! ableton_managed_path_allowed config "$path" \
                && ! ableton_managed_path_allowed symlink "$path"; } \
           || [ -n "${seen[$path]+x}" ]; then
            ableton_config_error "pre-install state is invalid or ambiguous"
            return 1
        fi
        expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
        if [ "$backup" != "$expected" ] \
           || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
            ableton_config_error "pre-install backup is missing or misplaced for $path"
            return 1
        fi
        digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
        [ -n "$digest" ] || {
            ableton_config_error "pre-install backup is unreadable for $path"
            return 1
        }
        seen["$path"]=1
    done < "$index"
    return 0
}

ableton_validate_mime_prestate()
{
    local state="${1:-$ABLETON_STATE_HOME/mime-prestate.tsv}"
    local type prior extra
    local -A seen=()
    if [ ! -e "$state" ] && [ ! -L "$state" ]; then return 0; fi
    [ -f "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] || {
        ableton_config_error "MIME restoration state is unsafe or unreadable"
        return 1
    }
    ableton_file_has_no_nul "$state" || {
        ableton_config_error "MIME restoration state contains invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r type prior extra || [ -n "$type$prior$extra" ]; do
        [ -z "$extra" ] && [ -n "$type" ] && [ -z "${seen[$type]+x}" ] || {
            ableton_config_error "MIME restoration state is invalid or ambiguous"
            return 1
        }
        case "$type" in
            x-scheme-handler/ableton|application/x-wine-extension-auz|\
            application/x-ableton-live-set|application/x-ableton-live-clip|\
            application/x-ableton-live-pack|application/x-ableton-live-max-device|\
            x-scheme-handler/c74max) ;;
            *) ableton_config_error "MIME restoration state has an unknown type"; return 1 ;;
        esac
        [ -z "$prior" ] || [[ "$prior" =~ ^[A-Za-z0-9_.+-]+[.]desktop$ ]] || {
            ableton_config_error "MIME restoration state has an invalid desktop entry"
            return 1
        }
        seen["$type"]=1
    done < "$state"
    return 0
}

ableton_validate_install_state_journals()
{
    local index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local backup_dir="$ABLETON_STATE_HOME/install-prestate" slot name expected count=0 indexed=0
    local -A slots=()
    ableton_validate_ownership_manifest \
        "$ABLETON_STATE_HOME/install-manifest.tsv" || return 1
    ableton_validate_prestate_index "$index" || return 1
    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
        [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || {
            ableton_config_error "pre-install backup directory is unsafe"
            return 1
        }
        while IFS= read -r -d '' slot; do
            name="${slot##*/}"
            [[ "$name" =~ ^[0-9a-f]{64}$ ]] \
                && { [ -f "$slot" ] || [ -L "$slot" ]; } \
                && [ -n "$(ableton_manifest_digest "$slot" 2>/dev/null || true)" ] || {
                ableton_config_error "pre-install backup directory contains an unsafe object"
                return 1
            }
            slots["$name"]=1
            count=$((count + 1))
        done < <(find "$backup_dir" -mindepth 1 -maxdepth 1 -print0)
    fi
    if [ -e "$index" ]; then
        while IFS=$'\t' read -r _ path _ _; do
            expected="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
            [ -n "${slots[$expected]+x}" ] || {
                ableton_config_error "pre-install backup inventory is incomplete"
                return 1
            }
            indexed=$((indexed + 1))
        done < "$index"
    fi
    [ "$count" -eq "$indexed" ] || {
        ableton_config_error "pre-install backup directory contains an unindexed object"
        return 1
    }
}

ableton_legacy_owned_path()
{
    local path="$1" data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    case "$path" in
        "$ABLETON_BIN_HOME/pipeasio-settings")
            [ -r "$ABLETON_DATA_HOME/VERSION" ] && [ -L "$path" ] \
                && [ "$(readlink -- "$path")" = "$ABLETON_WINE_ROOT/bin/pipeasio-settings" ]
            return ;;
        *) [ -f "$path" ] && [ ! -L "$path" ] || return 1 ;;
    esac
    case "$path" in
        "$ABLETON_DATA_HOME/ableton-linkd")
            strings "$path" 2>/dev/null | grep -qF 'ableton-linkd: native Ableton Link session anchor and probe' ;;
        "$ABLETON_DATA_HOME/setup-link.sh") grep -qF 'Ableton Link setup' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/ableton-linkctl") grep -qF 'Project-owned Ableton Link lifecycle controller' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/ableton-linkd.service") grep -qF 'ableton-linkd' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/VERSION") return 1 ;;
        "$ABLETON_DATA_HOME/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$ABLETON_DATA_HOME/wine-protocol-ableton.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'MimeType=x-scheme-handler/ableton;' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/ableton-live %u" "$path" \
                && grep -qxF 'NoDisplay=true' "$path" ;;
        "$ABLETON_DATA_HOME/$ABLETON_AUZ_DESKTOP_ID"|\
        "$ABLETON_DATA_HOME/wine-extension-auz.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'MimeType=application/x-wine-extension-auz;' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/ableton-live %f" "$path" \
                && grep -qxF 'NoDisplay=true' "$path" ;;
        "$ABLETON_DATA_HOME/detect-scale.sh") grep -qF 'Sourceable display-scale detection' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/detect-theme.sh") grep -qF 'Sourceable theme detection helpers' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/lib/live-components.sh") grep -qF 'Opt-in payload removal' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/shortcut-hold.sh") grep -qF 'GNOME shortcut hold' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/setsyscolors.exe"|"$ABLETON_DATA_HOME/learnheal.exe") return 1 ;;
        "$ABLETON_BIN_HOME/ableton-live") grep -qF 'Ableton Live launcher for the patched Wine stack' "$path" 2>/dev/null ;;
        "$ABLETON_BIN_HOME/max9") grep -qF 'Max 9 launcher' "$path" 2>/dev/null ;;
        "$ABLETON_BIN_HOME/pipeasio-settings") return 0 ;;
        "$data_root/applications/pipeasio-settings.desktop")
            [ -r "$ABLETON_DATA_HOME/VERSION" ] && [ -f "$path" ] && [ ! -L "$path" ] \
                && grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'Name=PipeASIO Settings' "$path" \
                && grep -qxF 'Icon=pipeasio' "$path" \
                && { grep -qxF "Exec=$ABLETON_BIN_HOME/pipeasio-settings" "$path" \
                     || grep -qxF 'X-Ableton-Wine-Managed=true' "$path"; } ;;
        "$data_root/icons/hicolor/scalable/apps/pipeasio.svg")
            [ -r "$ABLETON_DATA_HOME/VERSION" ] && [ -f "$path" ] && [ ! -L "$path" ] \
                && [ -f "$ABLETON_WINE_ROOT/share/icons/hicolor/scalable/apps/pipeasio.svg" ] \
                && cmp -s -- "$ABLETON_WINE_ROOT/share/icons/hicolor/scalable/apps/pipeasio.svg" "$path" ;;
        "$data_root/applications/ableton-live.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'Comment=Music production and performance' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/ableton-live %f" "$path" \
                && grep -qxF 'MimeType=application/x-ableton-live-set;application/x-ableton-live-clip;application/x-ableton-live-pack;' "$path" ;;
        "$data_root/applications/max9.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'Name=Max 9' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/max9 %f" "$path" \
                && grep -qxF 'MimeType=application/x-ableton-live-max-device;' "$path" ;;
        "$data_root/applications/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$data_root/applications/wine-protocol-ableton.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'MimeType=x-scheme-handler/ableton;' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/ableton-live %u" "$path" \
                && grep -qxF 'NoDisplay=true' "$path" ;;
        "$data_root/applications/$ABLETON_AUZ_DESKTOP_ID"|\
        "$data_root/applications/wine-extension-auz.desktop")
            grep -qxF 'Type=Application' "$path" \
                && grep -qxF 'MimeType=application/x-wine-extension-auz;' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/ableton-live %f" "$path" \
                && grep -qxF 'NoDisplay=true' "$path" ;;
        "$data_root/applications/wine-protocol-c74max.desktop")
            grep -qxF 'MimeType=x-scheme-handler/c74max;' "$path" \
                && grep -qxF "Exec=$ABLETON_BIN_HOME/max9 %u" "$path" \
                && grep -qxF 'NoDisplay=true' "$path" ;;
        "$data_root/mime/packages/x-wine-extension-auz.xml")
            grep -qF '<mime-type type="application/x-wine-extension-auz">' "$path" \
                && grep -qF '<glob pattern="*.auz"/>' "$path" ;;
        "$data_root/mime/packages/application-ableton-live.xml")
            grep -qF '<mime-type type="application/x-ableton-live-set">' "$path" \
                && grep -qF '<mime-type type="application/x-ableton-live-max-device">' "$path" \
                && grep -qF '<glob pattern="*.als"/>' "$path" \
                && grep -qF '<glob pattern="*.amxd"/>' "$path" ;;
        *) return 1 ;;
    esac
}

ableton_persist_file_prestate()
{
    local target="$1" source="${2:-}" manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    local index="$ABLETON_STATE_HOME/install-prestate.tsv" prestate_dir id backup expected current index_tmp
    if [ -d "$target" ] && [ ! -L "$target" ]; then
        ableton_config_error "refusing to preserve a directory as file pre-state: $target"
        return 1
    fi
    if ! ableton_managed_path_allowed file "$target" \
       && ! ableton_managed_path_allowed config "$target" \
       && ! ableton_managed_path_allowed symlink "$target"; then
        ableton_config_error "refusing to preserve a path outside the managed integration set: $target"
        return 1
    fi
    ableton_validate_install_state_journals || return 1
    [ -e "$target" ] || [ -L "$target" ] || return 0
    [ -z "$source" ] || [ -L "$target" ] || ! cmp -s -- "$source" "$target" || return 0
    if [ -r "$manifest" ]; then
        expected="$(awk -F '\t' -v p="$target" \
            '($1=="file" || $1=="config" || $1=="symlink") && $2==p { print $3; exit }' "$manifest")"
        if [ -n "$expected" ]; then
            current="$(ableton_manifest_digest "$target" 2>/dev/null || true)"
            [ "$current" = "$expected" ] && return 0
            ableton_config_error "refusing to overwrite modified managed file $target"
            return 1
        fi
    fi
    if [ -r "$index" ] && awk -F '\t' -v p="$target" '$2==p { found=1 } END { exit !found }' "$index"; then
        return 0
    fi
    ableton_legacy_owned_path "$target" && return 0
    ableton_mark_state_home
    prestate_dir="$ABLETON_STATE_HOME/install-prestate"
    if [ -e "$prestate_dir" ] || [ -L "$prestate_dir" ]; then
        [ -d "$prestate_dir" ] && [ ! -L "$prestate_dir" ] || {
            ableton_config_error "pre-install backup directory is unsafe"
            return 1
        }
    else
        mkdir -- "$prestate_dir" || return 1
    fi
    ableton_txn_snapshot "$index"
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
    backup="$prestate_dir/$id"
    [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
        ableton_config_error "unindexed pre-install backup already exists for $target"
        return 1
    }
    ableton_txn_snapshot "$backup"
    index_tmp="$(mktemp "$ABLETON_STATE_HOME/.prestate.XXXXXX")" || return 1
    [ ! -e "$index" ] || cp -- "$index" "$index_tmp" || { rm -f -- "$index_tmp"; return 1; }
    if ! printf 'present\t%s\t%s\n' "$target" "$backup" >> "$index_tmp" \
       || ! chmod 600 "$index_tmp" \
       || ! ableton_txn_expect "$backup" "$(ableton_object_token "$target")" \
       || ! ableton_txn_expect "$index" "$(ableton_regular_source_token "$index_tmp")" \
       || ! ableton_atomic_restore_object "$target" "$backup" \
       || ! mv -f -- "$index_tmp" "$index"; then
        rm -f -- "$index_tmp"
        return 1
    fi
}

ableton_install_file()
{
    local mode="$1" source="$2" target="$3" kind="${4:-file}" post tmp parent
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "refusing to replace directory with a file: $target"
        return 1
    }
    ableton_persist_file_prestate "$target" "$source"
    ableton_txn_snapshot "$target"
    post="$(ableton_regular_source_token "$source")" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    parent="$(dirname "$target")"
    mkdir -p -- "$parent"
    tmp="$(mktemp "$parent/.ableton-install.XXXXXX")" || return 1
    if ! install -m "$mode" -- "$source" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$post" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    ableton_record_owned "$target" "$kind"
}

ableton_copy_file()
{
    local source="$1" target="$2" kind="${3:-file}" post tmp parent
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "refusing to replace directory with a file: $target"
        return 1
    }
    ableton_persist_file_prestate "$target" "$source"
    ableton_txn_snapshot "$target"
    post="$(ableton_object_token "$source")" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    parent="$(dirname "$target")"
    mkdir -p -- "$parent"
    tmp="$(mktemp "$parent/.ableton-copy.XXXXXX")" || return 1
    rm -f -- "$tmp" || return 1
    if ! cp -a -- "$source" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$post" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    ableton_record_owned "$target" "$kind"
}

ableton_install_symlink()
{
    local link_text="$1" target="$2" post tmp parent
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "refusing to replace directory with a symlink: $target"
        return 1
    }
    ableton_persist_file_prestate "$target"
    ableton_txn_snapshot "$target"
    post="$(ableton_symlink_text_token "$link_text")" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    parent="$(dirname "$target")"
    mkdir -p -- "$parent"
    tmp="$(mktemp "$parent/.ableton-link.XXXXXX")" || return 1
    rm -f -- "$tmp" || return 1
    if ! ln -s -- "$link_text" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$post" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    ableton_record_owned "$target" symlink
}

ableton_adopt_runtime_marker()
{
    local runtime="$1" runtime_name="${2:-$ABLETON_RUNTIME_NAME}"
    local marker="$runtime/.ableton-linux-runtime" marker_tmp
    ableton_runtime_marker_valid "$runtime" "$runtime_name" && return 0
    ableton_legacy_default_runtime_valid "$runtime" || {
        ableton_config_error "runtime is neither exactly marked nor a recognised legacy installation: $runtime"
        return 1
    }
    ableton_txn_snapshot "$marker" || return 1
    marker_tmp="$(mktemp "$runtime/.runtime-marker.XXXXXX")" || return 1
    if ! printf 'format=1\nname=%s\n' "$runtime_name" > "$marker_tmp" \
       || ! chmod 600 "$marker_tmp" \
       || ! ableton_txn_expect "$marker" "$(ableton_regular_source_token "$marker_tmp")" \
       || ! mv -T -n -- "$marker_tmp" "$marker" \
       || [ -e "$marker_tmp" ] \
       || ! ableton_runtime_marker_valid "$runtime" "$runtime_name"; then
        rm -f -- "$marker_tmp"
        ableton_config_error "could not adopt the legacy runtime safely"
        return 1
    fi
}

ableton_adopt_prefix_marker()
{
    local prefix="$1" expected_prefix="${2:-$1}"
    local marker="$prefix/.ableton-linux-prefix" marker_tmp
    ableton_prefix_marker_valid "$prefix" "$expected_prefix" && return 0
    ableton_legacy_default_prefix_valid "$prefix" || {
        ableton_config_error "prefix is neither exactly marked nor a recognised legacy installation: $prefix"
        return 1
    }
    ableton_txn_snapshot "$marker" || return 1
    marker_tmp="$(mktemp "$prefix/.prefix-marker.XXXXXX")" || return 1
    if ! printf 'format=1\nprefix=%s\n' "$expected_prefix" > "$marker_tmp" \
       || ! chmod 600 "$marker_tmp" \
       || ! ableton_txn_expect "$marker" "$(ableton_regular_source_token "$marker_tmp")" \
       || ! mv -T -n -- "$marker_tmp" "$marker" \
       || [ -e "$marker_tmp" ] \
       || ! ableton_prefix_marker_valid "$prefix" "$expected_prefix"; then
        rm -f -- "$marker_tmp"
        ableton_config_error "could not adopt the legacy prefix safely"
        return 1
    fi
}

ableton_remove_managed_file()
{
    local target="$1" index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local id backup recorded="" index_tmp row_count=0 present_count=0 backup_digest restored_digest
    ableton_validate_install_state_journals || return 1
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
    backup="$ABLETON_STATE_HOME/install-prestate/$id"
    if [ -r "$index" ]; then
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")"
        present_count="$(awk -F '\t' -v p="$target" \
            '$1=="present" && $2==p { n++ } END { print n+0 }' "$index")"
        recorded="$(awk -F '\t' -v p="$target" \
            '$1=="present" && $2==p { print $3; exit }' "$index")"
        if [ "$row_count" -ne 0 ]; then
            if [ "$row_count" -ne 1 ] || [ "$present_count" -ne 1 ] \
               || [ "$recorded" != "$backup" ] \
               || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
                ableton_config_error "cannot safely restore pre-install file $target"
                return 1
            fi
            backup_digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
            [ -n "$backup_digest" ] || {
                ableton_config_error "cannot read pre-install file for $target"
                return 1
            }
        fi
    fi
    ableton_txn_snapshot "$target" || return 1
    if [ -n "$recorded" ]; then
        ableton_txn_expect "$target" "$(ableton_object_token "$backup")" || return 1
    else
        ableton_txn_expect "$target" absent || return 1
    fi
    rm -f -- "$target" || return 1
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
    if [ -n "$recorded" ]; then
        ableton_txn_snapshot "$index" || return 1
        ableton_txn_snapshot "$backup" || return 1
        ableton_atomic_restore_object "$backup" "$target" || return 1
        restored_digest="$(ableton_manifest_digest "$target" 2>/dev/null || true)"
        [ "$restored_digest" = "$backup_digest" ] || return 1
        index_tmp="$(mktemp "$ABLETON_STATE_HOME/.prestate.XXXXXX")" || return 1
        if ! awk -F '\t' -v p="$target" '$2 != p { print }' "$index" > "$index_tmp" \
           || ! chmod 600 "$index_tmp" \
           || ! ableton_txn_expect "$index" "$(ableton_regular_source_token "$index_tmp")" \
           || ! mv -f -- "$index_tmp" "$index"; then
            rm -f -- "$index_tmp"
            return 1
        fi
        ableton_txn_expect "$backup" absent || return 1
        rm -f -- "$backup" || return 1
        printf '   restored your previous %s\n' "$target"
    fi
    ableton_record_deowned "$target"
}

# Relinquish a historical ownership claim after the user changed the object.
# The live path is untouched; any installer-only prestate is consumed so a
# later uninstall cannot resurrect or remove the user's replacement.
ableton_abandon_managed_file()
{
    local target="$1" index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local id backup recorded="" index_tmp row_count=0
    ableton_validate_install_state_journals || return 1
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
    backup="$ABLETON_STATE_HOME/install-prestate/$id"
    if [ -r "$index" ]; then
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")"
        recorded="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { print $3; exit }' "$index")"
        if [ "$row_count" -ne 0 ]; then
            if ! { [ "$row_count" -eq 1 ] && [ "$recorded" = "$backup" ] \
                   && { [ -f "$backup" ] || [ -L "$backup" ]; }; }; then
                ableton_config_error "cannot safely relinquish pre-install state for $target"
                return 1
            fi
            ableton_txn_snapshot "$index" || return 1
            ableton_txn_snapshot "$backup" || return 1
            index_tmp="$(mktemp "$ABLETON_STATE_HOME/.prestate.XXXXXX")" || return 1
            if ! awk -F '\t' -v p="$target" '$2 != p { print }' "$index" > "$index_tmp" \
               || ! chmod 600 "$index_tmp" \
               || ! ableton_txn_expect "$index" "$(ableton_regular_source_token "$index_tmp")" \
               || ! ableton_txn_expect "$backup" absent \
               || ! mv -f -- "$index_tmp" "$index" \
               || ! rm -f -- "$backup"; then
                rm -f -- "$index_tmp"
                return 1
            fi
        fi
    fi
    ableton_record_deowned "$target"
}

# Retire the narrowly authenticated PR #182 custom Link object without a
# check-then-delete window. The live object is claimed by an atomic same-dir
# rename, journaled from that exact object, and only then compared with the
# immutable proof. A changed object is restored and de-owned; it is never
# replaced by the historical prestate.
ableton_retire_pr182_custom_link()
{
    local target="$1" proof="$ABLETON_TRANSACTION_DIR/pr182-custom-link"
    local metadata="$proof/metadata" expected_digest expected_token
    local index="$ABLETON_STATE_HOME/install-prestate.tsv" id prestate_backup="" prestate_token=""
    local row_count=0 parent claim_dir capture captured_token captured_identity
    local stage_dir="" staged="" staged_token="" staged_identity="" final_token=absent
    local current_token current_identity
    ABLETON_PR182_RETIREMENT=""
    export ABLETON_PR182_RETIREMENT
    ableton_txn_pr182_custom_link_authorized "$target" || return 1
    ableton_validate_install_state_journals || return 1
    expected_digest="$(sed -n '3s/^recorded_digest=//p' "$metadata")"
    [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    expected_token="file:$expected_digest"

    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" || return 1
    if [ -r "$index" ]; then
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")"
        if [ "$row_count" -eq 1 ]; then
            prestate_backup="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { print $3 }' "$index")"
            [ "$prestate_backup" = "$ABLETON_STATE_HOME/install-prestate/$id" ] \
                && { [ -f "$prestate_backup" ] || [ -L "$prestate_backup" ]; } || return 1
            prestate_token="$(ableton_object_token "$prestate_backup")" || return 1
        elif [ "$row_count" -ne 0 ]; then
            return 1
        fi
    fi

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        ableton_abandon_managed_file "$target" || return 1
        ABLETON_PR182_RETIREMENT=deowned
        return 0
    fi
    { [ -f "$target" ] || [ -L "$target" ]; } && [ ! -d "$target" ] || {
        ableton_config_error "historical custom Link path has an unsafe object: $target"
        return 1
    }

    # This read is intentionally non-authoritative. It proves the live object
    # is readable, but only the subsequently renamed capture decides whether
    # it is the historical managed object or a user replacement.
    current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
    [ -n "$current_token" ] || return 1

    parent="$(dirname "$target")"
    claim_dir="$(mktemp -d "$parent/.ableton-pr182-retire.XXXXXX")" || return 1
    capture="$claim_dir/object"

    # Keep the captured object reachable until its position-bound journal row
    # is durable. A replacement that appears in this short window is preserved
    # alongside the capture and makes the whole transaction fail closed.
    trap '' INT TERM
    if ! mv -T -n -- "$target" "$capture"; then
        trap 'exit 130' INT
        trap 'exit 143' TERM
        rmdir -- "$claim_dir" 2>/dev/null || true
        ableton_config_error "could not atomically claim the historical custom Link object"
        return 1
    fi
    if { [ ! -f "$capture" ] && [ ! -L "$capture" ]; }; then
        trap 'exit 130' INT
        trap 'exit 143' TERM
        rmdir -- "$claim_dir" 2>/dev/null || true
        ableton_config_error "could not atomically claim the historical custom Link object"
        return 1
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        ableton_txn_mark_concurrent_conflict "$target" || true
        trap 'exit 130' INT
        trap 'exit 143' TERM
        ableton_config_error "custom Link changed during retirement; preserved capture at $capture"
        return 1
    fi
    if ! ableton_txn_snapshot_captured "$target" "$capture"; then
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            mv -T -n -- "$capture" "$target" >/dev/null 2>&1 || true
        fi
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [ -e "$capture" ] || [ -L "$capture" ]; then
            ableton_config_error "could not journal the historical custom Link object; preserved capture at $capture"
        else
            rmdir -- "$claim_dir" 2>/dev/null || true
            ableton_config_error "could not journal the historical custom Link object"
        fi
        return 1
    fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    captured_token="$(ableton_object_token "$capture" 2>/dev/null || true)"
    captured_identity="$(stat -c '%d:%i' -- "$capture" 2>/dev/null || true)"
    if [ -z "$captured_token" ] || [ -z "$captured_identity" ]; then
        ableton_txn_mark_concurrent_conflict "$target" || true
        ableton_config_error "captured custom Link object became unreadable; transaction retained"
        return 1
    fi

    if [ "$captured_token" != "$expected_token" ]; then
        # Preserve the exact changed object. If another replacement appeared
        # during the claim, retain both objects and fail rather than choosing
        # one or overwriting either.
        if [ -e "$target" ] || [ -L "$target" ] \
           || ! mv -T -n -- "$capture" "$target" \
           || [ -e "$capture" ] || [ -L "$capture" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link changed during retirement; preserved capture at $capture"
            return 1
        fi
        current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
        current_identity="$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)"
        if [ "$current_token" != "$captured_token" ] \
           || [ "$current_identity" != "$captured_identity" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link changed while its ownership was being relinquished"
            return 1
        fi
        ableton_txn_expect "$target" "$captured_token" || return 1
        ableton_abandon_managed_file "$target" || return 1
        current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
        current_identity="$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)"
        if [ "$current_token" != "$captured_token" ] \
           || [ "$current_identity" != "$captured_identity" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link changed while its ownership was being relinquished"
            return 1
        fi
        rmdir -- "$claim_dir" || return 1
        ABLETON_PR182_RETIREMENT=deowned
        return 0
    fi

    # If a new object appeared after the owned object was captured, preserve
    # both objects and fail closed. The transaction journal correctly holds the
    # captured prior object; reporting success here would let a later outer
    # rollback overwrite the concurrently created object with that backup.
    if [ -e "$target" ] || [ -L "$target" ]; then
        ableton_txn_mark_concurrent_conflict "$target" || true
        ableton_config_error "custom Link changed during retirement; preserved capture at $capture"
        return 1
    fi

    if [ -n "$prestate_backup" ]; then
        stage_dir="$(mktemp -d "$parent/.ableton-pr182-prestate.XXXXXX")" || return 1
        staged="$stage_dir/object"
        if ! cp -a -- "$prestate_backup" "$staged"; then
            rmdir -- "$stage_dir" 2>/dev/null || true
            return 1
        fi
        staged_token="$(ableton_object_token "$staged" 2>/dev/null || true)"
        staged_identity="$(stat -c '%d:%i' -- "$staged" 2>/dev/null || true)"
        if [ "$staged_token" != "$prestate_token" ] || [ -z "$staged_identity" ] \
           || [ -e "$target" ] || [ -L "$target" ] \
           || ! mv -T -n -- "$staged" "$target" \
           || [ -e "$staged" ] || [ -L "$staged" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link changed before its previous file could be restored; preserved capture at $capture"
            return 1
        fi
        rmdir -- "$stage_dir" || return 1
        current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
        current_identity="$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)"
        if [ "$current_token" != "$prestate_token" ] \
           || [ "$current_identity" != "$staged_identity" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "restored custom Link prestate changed during retirement"
            return 1
        fi
        final_token="$prestate_token"
        ableton_txn_expect "$target" "$final_token" || return 1
    else
        ableton_txn_expect "$target" absent || return 1
    fi

    # The captured historical object is no longer needed after the known final
    # state is published. Recheck immediately after deletion, then consume only
    # metadata. A wrapper/racer that creates a new object during this deletion
    # is preserved and makes the transaction permanently conflicting.
    rm -f -- "$capture" || return 1
    current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
    if [ "$current_token" != "$final_token" ]; then
        ableton_txn_mark_concurrent_conflict "$target" || true
        ableton_config_error "custom Link changed after retirement capture; preserved the new object"
        return 1
    fi
    if [ "$final_token" != absent ]; then
        current_identity="$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)"
        if [ "$current_identity" != "$staged_identity" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link object identity changed after prestate restoration"
            return 1
        fi
    fi
    ableton_abandon_managed_file "$target" || return 1
    current_token="$(ableton_object_token "$target" 2>/dev/null || true)"
    if [ "$current_token" != "$final_token" ]; then
        ableton_txn_mark_concurrent_conflict "$target" || true
        ableton_config_error "custom Link changed while its historical ownership was being removed"
        return 1
    fi
    if [ "$final_token" != absent ]; then
        current_identity="$(stat -c '%d:%i' -- "$target" 2>/dev/null || true)"
        if [ "$current_identity" != "$staged_identity" ]; then
            ableton_txn_mark_concurrent_conflict "$target" || true
            ableton_config_error "custom Link object identity changed while ownership was being removed"
            return 1
        fi
        printf '   restored your previous %s\n' "$target"
    fi
    rmdir -- "$claim_dir" || return 1
    ABLETON_PR182_RETIREMENT=retired
}

ableton_write_ownership_manifest()
{
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv" tmp path digest
    ableton_validate_install_state_journals || return 1
    ableton_mark_state_home
    ableton_txn_snapshot "$manifest"
    tmp="$(mktemp "$ABLETON_STATE_HOME/.manifest.XXXXXX")"
    # Preserve records for components this invocation did not touch.  Touched
    # paths are replaced below by their new digest.
    if [ -r "$manifest" ]; then
        while IFS=$'\t' read -r kind path digest; do
            case "$kind" in file|config|symlink|runtime) ;; *) continue ;; esac
            [ -n "$path" ] || continue
            [ -z "${ABLETON_MANIFEST_TOUCHED[$path]+x}" ] || continue
            printf '%s\t%s\t%s\n' "$kind" "$path" "$digest" >> "$tmp"
        done < "$manifest"
    fi
    for path in "${ABLETON_OWNED_PATHS[@]}"; do
        [ -z "${ABLETON_MANIFEST_DEOWNED[$path]+x}" ] || continue
        [ -f "$path" ] || [ -L "$path" ] || continue
        digest="$(ableton_manifest_digest "$path")"
        printf '%s\t%s\t%s\n' "${ABLETON_OWNED_KINDS[$path]:-file}" "$path" "$digest" >> "$tmp"
    done
    if [ "${ABLETON_RUNTIME_INSTALLED:-0}" -eq 1 ]; then
        printf 'runtime\t%s\t%s\n' "$ABLETON_WINE_ROOT" "$ABLETON_RUNTIME_NAME" >> "$tmp"
    fi
    sort -u "$tmp" -o "$tmp"
    chmod 600 "$tmp"
    ableton_txn_expect "$manifest" "$(ableton_regular_source_token "$tmp")"
    mv -f -- "$tmp" "$manifest"
}

ableton_txn_rollback_files()
{
    local txn="$1" status path backup post extra rc=0 i digest
    local -a statuses=() paths=() backups=()
    [ ! -e "$txn/files.tsv" ] && [ ! -L "$txn/files.tsv" ] && return 0
    ableton_txn_preflight_rollback_files "$txn" || return 1
    # Validate the complete journal before touching any live path.  Snapshot
    # backups are position-bound so a corrupt row cannot substitute unrelated
    # content from elsewhere on disk.
    while IFS=$'\t' read -r status path backup post extra \
          || [ -n "$status$path$backup$post$extra" ]; do
        statuses+=("$status")
        paths+=("$path")
        backups+=("$backup")
    done < "$txn/files.tsv"

    for ((i=${#paths[@]}-1; i>=0; i--)); do
        status="${statuses[i]}" path="${paths[i]}" backup="${backups[i]}"
        case "$status" in
            absent)
                if ! rm -f -- "$path" || [ -e "$path" ] || [ -L "$path" ]; then rc=1; fi ;;
            present)
                if ! ableton_atomic_restore_object "$backup" "$path"; then rc=1; continue; fi
                digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
                [ -n "$digest" ] \
                    && [ "$(ableton_manifest_digest "$path" 2>/dev/null || true)" = "$digest" ] \
                    || rc=1 ;;
        esac
    done
    return "$rc"
}

# Promote a prepared directory without ever leaving an unrecorded gap at the
# live path.  The transaction record becomes durable between the two atomic
# same-filesystem renames.  INT/TERM are ignored only across that short window;
# if record publication fails, the old tree is put back before signals resume.
ableton_promote_directory()
{
    local candidate="$1" target="$2" backup="$3" record="$4"
    local record_tmp expected old_moved=0 record_ok=0 promote_ok=0
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || {
        ableton_config_error "promotion candidate is missing or unsafe: $candidate"; return 1; }
    [ ! -e "$record" ] && [ ! -L "$record" ] || {
        ableton_config_error "promotion transaction record already exists: $record"; return 1; }
    if [ "$backup" = absent ]; then
        [ ! -e "$target" ] && [ ! -L "$target" ] || {
            ableton_config_error "promotion target unexpectedly exists: $target"; return 1; }
    else
        [ -d "$target" ] && [ ! -L "$target" ] \
            && [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
            ableton_config_error "promotion source or backup path is unsafe"; return 1; }
    fi
    expected="$(printf '%s\t%s\n' "$target" "$backup")"
    record_tmp="$(mktemp "$(dirname "$record")/.promotion.XXXXXX")" || return 1
    if ! printf '%s\n' "$expected" > "$record_tmp" || ! chmod 600 "$record_tmp"; then
        rm -f -- "$record_tmp"
        ableton_config_error "could not prepare the promotion transaction record"
        return 1
    fi

    trap '' INT TERM
    if [ "$backup" != absent ]; then
        mv -T -n -- "$target" "$backup" >/dev/null 2>&1 || true
        if [ ! -e "$target" ] && [ ! -L "$target" ] \
           && [ -d "$backup" ] && [ ! -L "$backup" ]; then
            old_moved=1
        else
            trap 'exit 130' INT; trap 'exit 143' TERM
            rm -f -- "$record_tmp"
            ableton_config_error "could not stage the current installation for promotion"
            return 1
        fi
    fi

    mv -T -n -- "$record_tmp" "$record" >/dev/null 2>&1 || true
    if [ ! -e "$record_tmp" ] && [ -f "$record" ] && [ ! -L "$record" ] \
       && [ "$(cat "$record" 2>/dev/null || true)" = "$expected" ]; then
        record_ok=1
    fi
    if [ "$record_ok" -ne 1 ]; then
        rm -f -- "$record" "$record_tmp"
        if [ "$old_moved" -eq 1 ]; then
            mv -T -n -- "$backup" "$target" >/dev/null 2>&1 || true
            if [ -e "$backup" ] || [ -L "$backup" ] \
               || [ ! -d "$target" ] || [ -L "$target" ]; then
                trap 'exit 130' INT; trap 'exit 143' TERM
                ableton_config_error "promotion record failed and the previous installation could not be restored"
                return 1
            fi
        fi
        trap 'exit 130' INT; trap 'exit 143' TERM
        ableton_config_error "could not publish the promotion transaction record; previous installation restored"
        return 1
    fi

    mv -T -n -- "$candidate" "$target" >/dev/null 2>&1 || true
    if [ ! -e "$candidate" ] && [ ! -L "$candidate" ] \
       && [ -d "$target" ] && [ ! -L "$target" ]; then
        promote_ok=1
    fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$promote_ok" -eq 1 ] || {
        ableton_config_error "could not promote the prepared installation; transaction rollback is required"
        return 1
    }
}
