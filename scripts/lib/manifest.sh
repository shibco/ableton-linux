#!/usr/bin/env bash
# File-level transaction and ownership manifest helpers for installer components.
# Paths containing newlines are rejected by config.sh; tab is rejected here so
# the on-disk records remain simple and auditable.

declare -Ag ABLETON_TXN_SEEN=()
declare -ag ABLETON_OWNED_PATHS=()
declare -Ag ABLETON_OWNED_KINDS=()
declare -Ag ABLETON_MANIFEST_TOUCHED=()
declare -Ag ABLETON_MANIFEST_DEOWNED=()
declare -gi ABLETON_OPTIONAL_FILE_FAILURES=0
declare -gi ABLETON_OPTIONAL_FILE_CANCELLED=0
declare -gi ABLETON_OPTIONAL_FILES_KEPT=0
declare -gi ABLETON_OPTIONAL_FILES_BACKED_UP=0
declare -gi ABLETON_PROJECT_OVERWRITE_ALL=0
declare -gi ABLETON_PROJECT_KEEP_ALL=0
declare -gi ABLETON_PUBLICATION_JOURNAL_BROKEN=0

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

ableton_launcher_path_allowed()
{
    local path="$1" data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    case "$path" in
        "$ABLETON_BIN_HOME/ableton-live"|"$ABLETON_BIN_HOME/max9"|\
        "$ABLETON_BIN_HOME/pipeasio-settings"|\
        "$ABLETON_DATA_HOME/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$ABLETON_DATA_HOME/$ABLETON_AUZ_DESKTOP_ID"|\
        "$data_root/applications/ableton-live.desktop"|\
        "$data_root/applications/$ABLETON_PROTOCOL_DESKTOP_ID"|\
        "$data_root/applications/$ABLETON_AUZ_DESKTOP_ID"|\
        "$data_root/applications/max9.desktop"|\
        "$data_root/applications/wine-protocol-c74max.desktop"|\
        "$data_root/applications/pipeasio-settings.desktop") return 0 ;;
        *) return 1 ;;
    esac
}

ableton_managed_path_allowed()
{
    local kind="$1" path="$2" data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
    local config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    case "$kind" in file|config|symlink) ;; *) return 1 ;; esac
    if ableton_launcher_path_allowed "$path"; then return 0; fi
    if [ "$kind" = config ]; then
        case "$path" in
            "$config_root/mimeapps.list"|\
            "$config_root/systemd/user/ableton-linkd.service") return 0 ;;
        esac
    fi
    case "$path" in
        *.bak) ableton_launcher_path_allowed "${path%.bak}" && return 0 ;;
    esac
    case "$path" in
        "$ABLETON_DATA_HOME/lib/config.sh"|"$ABLETON_DATA_HOME/lib/lifecycle.sh"|\
        "$ABLETON_DATA_HOME/lib/live-options.sh"|"$ABLETON_DATA_HOME/lib/manifest.sh"|\
        "$ABLETON_DATA_HOME/lib/pipeasio.sh"|"$ABLETON_DATA_HOME/lib/preferences.sh"|\
        "$ABLETON_DATA_HOME/lib/ui.sh"|\
        "$ABLETON_DATA_HOME/detect-scale.sh"|"$ABLETON_DATA_HOME/detect-theme.sh"|\
        "$ABLETON_DATA_HOME/shortcut-hold.sh"|"$ABLETON_DATA_HOME/setup-realtime.sh"|\
        "$ABLETON_DATA_HOME/audio-report.sh"|"$ABLETON_DATA_HOME/check-ntsync.sh"|\
        "$ABLETON_DATA_HOME/ntsyncprobe.exe"|"$ABLETON_DATA_HOME/rollback.sh"|\
        "$ABLETON_DATA_HOME/pipewire-version-probe"|"$ABLETON_DATA_HOME/setsyscolors.exe"|\
        "$ABLETON_DATA_HOME/learnheal.exe"|\
        "$ABLETON_DATA_HOME/wine-protocol-ableton.desktop"|\
        "$ABLETON_DATA_HOME/wine-extension-auz.desktop"|"$ABLETON_DATA_HOME/ableton-linkctl"|\
        "$ABLETON_DATA_HOME/setup-link.sh"|"$ABLETON_DATA_HOME/ableton-linkd.service"|\
        "$ABLETON_DATA_HOME/VERSION"|"$ABLETON_DATA_HOME/ableton-linkd"|\
        "$data_root/applications/wine-protocol-ableton.desktop"|\
        "$data_root/applications/wine-extension-auz.desktop"|\
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

# Only private support files may use the overwrite-without-prestate policy.
# Launchers have their own adjacent .bak policy, while shared icon/MIME paths
# must continue preserving an unrelated file that already occupies the name.
ableton_replace_generated_path_allowed()
{
    case "$1" in
        "$ABLETON_DATA_HOME/lib/config.sh"|"$ABLETON_DATA_HOME/lib/lifecycle.sh"|\
        "$ABLETON_DATA_HOME/lib/live-options.sh"|"$ABLETON_DATA_HOME/lib/manifest.sh"|\
        "$ABLETON_DATA_HOME/lib/pipeasio.sh"|"$ABLETON_DATA_HOME/lib/preferences.sh"|\
        "$ABLETON_DATA_HOME/detect-scale.sh"|"$ABLETON_DATA_HOME/detect-theme.sh"|\
        "$ABLETON_DATA_HOME/shortcut-hold.sh"|"$ABLETON_DATA_HOME/setup-realtime.sh"|\
        "$ABLETON_DATA_HOME/audio-report.sh"|"$ABLETON_DATA_HOME/check-ntsync.sh"|\
        "$ABLETON_DATA_HOME/rollback.sh"|"$ABLETON_DATA_HOME/ntsyncprobe.exe"|\
        "$ABLETON_DATA_HOME/pipewire-version-probe"|\
        "$ABLETON_DATA_HOME/setsyscolors.exe"|"$ABLETON_DATA_HOME/learnheal.exe"|\
        "$ABLETON_DATA_HOME/VERSION"|"$ABLETON_DATA_HOME/ableton-linkd"|\
        "$ABLETON_DATA_HOME/ableton-linkctl"|"$ABLETON_DATA_HOME/setup-link.sh"|\
        "$ABLETON_DATA_HOME/ableton-linkd.service") return 0 ;;
        *) return 1 ;;
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
    local runtime_parent runtime_base candidate relative root parent_real root_real desktop_dir="" launcher

    if ableton_managed_path_allowed file "$path" \
       || ableton_managed_path_allowed config "$path" \
       || ableton_managed_path_allowed symlink "$path"; then
        return 0
    fi
    case "$path" in
        *.bak)
            launcher="${path%.bak}"
            ableton_launcher_path_allowed "$launcher" && return 0 ;;
    esac
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

ableton_txn_validate_files()
{
    local txn="$1" journal="$1/files.tsv" status path backup post extra index=0 expected digest
    local -A seen=()
    [ -d "$txn" ] && [ ! -L "$txn" ] || {
        ableton_config_error "transaction directory is missing or unsafe"
        return 1
    }
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
        ableton_txn_post_valid "$post" || {
            ableton_config_error "invalid post-operation token in file transaction row $index"
            return 1
        }
        ableton_txn_target_allowed "$status" "$path" "$backup" || {
            ableton_config_error "file transaction target is outside the allowed lifecycle scope: $path"
            return 1
        }
        index=$((index + 1))
    done < "$journal"
    return 0
}

ableton_txn_object_token_valid()
{
    case "$1" in
        absent) return 0 ;;
        file:*|symlink:*) [[ "${1#*:}" =~ ^[0-9a-f]{64}$ ]] ;;
        *) return 1 ;;
    esac
}

# The final token is the committed generation.  A second, preceding token is
# the exact installer generation that was live immediately before publication.
# Keeping both closes the expect->rename failure window: rollback may accept
# either generation, while commit still accepts only the final one.
ableton_txn_post_valid()
{
    local post="$1" token
    local -a tokens=()
    [ "$post" != pending ] || return 0
    case "$post" in ''|,*|*,|*,,*) return 1 ;; esac
    IFS=, read -r -a tokens <<< "$post"
    [ "${#tokens[@]}" -ge 1 ] && [ "${#tokens[@]}" -le 2 ] || return 1
    for token in "${tokens[@]}"; do
        ableton_txn_object_token_valid "$token" || return 1
    done
    [ "${#tokens[@]}" -ne 2 ] || [ "${tokens[0]}" != "${tokens[1]}" ]
}

ableton_txn_post_final()
{
    local post="$1"
    ableton_txn_post_valid "$post" && [ "$post" != pending ] || return 1
    printf '%s\n' "${post##*,}"
}

ableton_txn_post_accepts()
{
    local post="$1" wanted="$2" token
    local -a tokens=()
    ableton_txn_post_valid "$post" && [ "$post" != pending ] || return 1
    IFS=, read -r -a tokens <<< "$post"
    for token in "${tokens[@]}"; do
        [ "$token" != "$wanted" ] || return 0
    done
    return 1
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
                && ! ableton_txn_post_accepts "$post" "$current"; }; then
            ableton_config_error "A file changed while the installer was restoring it: $path"
            return 1
        fi
    done < "$txn/files.tsv"
}

ableton_txn_preflight_commit_files()
{
    local txn="$1" status path backup post extra current final
    ableton_txn_validate_files "$txn" || return 1
    [ -e "$txn/files.tsv" ] || return 0
    while IFS=$'\t' read -r status path backup post extra \
          || [ -n "$status$path$backup$post$extra" ]; do
        [ "${post:-pending}" != pending ] || {
            ableton_config_error "A file update stopped before it finished: $path"
            return 1
        }
        final="$(ableton_txn_post_final "$post")" || return 1
        current="$(ableton_object_token "$path" 2>/dev/null || true)"
        [ "$current" = "$final" ] || {
            ableton_config_error "A file changed while the installer was updating it: $path"
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

# Generated integration files are independent repairs. Once one publication
# has reached its final token, retire only that file-level recovery data so a
# later optional failure cannot undo an earlier successful repair.
ableton_txn_checkpoint_files()
{
    local txn="${ABLETON_TRANSACTION_DIR:-}" journal files tmp key
    [ -n "$txn" ] || return 0
    if ! ableton_txn_preflight_commit_files "$txn"; then
        ABLETON_PUBLICATION_JOURNAL_BROKEN=1
        echo "!! A support file was updated, but temporary installer data could not be refreshed. Continuing with the installed file." >&2 \
            || true
        return 0
    fi
    journal="$txn/files.tsv"
    files="$txn/files"
    if ! tmp="$(mktemp "$txn/.files.tsv.XXXXXX")"; then
        ABLETON_PUBLICATION_JOURNAL_BROKEN=1
        echo "!! A support file was updated, but temporary installer data could not be refreshed. Continuing with the installed file." >&2 \
            || true
        return 0
    fi
    if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$journal"; then
        rm -f -- "$tmp" 2>/dev/null || true
        ABLETON_PUBLICATION_JOURNAL_BROKEN=1
        echo "!! A support file was updated, but temporary installer data could not be refreshed. Continuing with the installed file." >&2 \
            || true
        return 0
    fi
    for key in "${!ABLETON_TXN_SEEN[@]}"; do
        case "$key" in "$txn"$'\t'*) unset 'ABLETON_TXN_SEEN[$key]' ;; esac
    done
    if ! rm -rf -- "$files" || ! mkdir -p -- "$files"; then
        ABLETON_PUBLICATION_JOURNAL_BROKEN=1
        echo "!! A support file was updated, but temporary installer data could not be removed. Continuing with the installed file." >&2 \
            || true
    fi
    return 0
}

ableton_txn_snapshot()
{
    local path="$1" id backup existing journal_tmp status backup_created=0 seen_key
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
    # One shell can deliberately switch journals (prefix-host owns prefix
    # configuration while the outer installer owns the shared manifest).  A
    # path-only cache makes a snapshot in one journal suppress the same path's
    # snapshot in another.  Scope the fast-path to the actual transaction.
    seen_key="$ABLETON_TRANSACTION_DIR"$'\t'"$path"
    [ -z "${ABLETON_TXN_SEEN[$seen_key]+x}" ] || return 0
    existing="$(awk -F '\t' -v p="$path" '$2==p { n++ } END { print n+0 }' \
        "$ABLETON_TRANSACTION_DIR/files.tsv")" || return 1
    if [ "$existing" -eq 1 ]; then
        ABLETON_TXN_SEEN["$seen_key"]=1
        return 0
    fi
    ABLETON_TXN_SEEN["$seen_key"]=1
    id="$(wc -l < "$ABLETON_TRANSACTION_DIR/files.tsv")" || {
        unset 'ABLETON_TXN_SEEN[$seen_key]'
        return 1
    }
    [[ "$id" =~ ^[0-9]+$ ]] || {
        unset 'ABLETON_TXN_SEEN[$seen_key]'
        return 1
    }
    backup="$ABLETON_TRANSACTION_DIR/files/$id"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
        unset 'ABLETON_TXN_SEEN[$seen_key]'
        ableton_config_error "transaction backup slot is already occupied: $backup"
        return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        if ! ableton_atomic_restore_object "$path" "$backup"; then
            unset 'ABLETON_TXN_SEEN[$seen_key]'
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
        unset 'ABLETON_TXN_SEEN[$seen_key]'
        return 1
    }
    if ! cp -- "$ABLETON_TRANSACTION_DIR/files.tsv" "$journal_tmp" \
       || ! printf '%s\t%s\t%s\tpending\n' "$status" "$path" "$backup" >> "$journal_tmp" \
       || ! chmod 600 "$journal_tmp" \
       || ! mv -f -- "$journal_tmp" "$ABLETON_TRANSACTION_DIR/files.tsv"; then
        rm -f -- "$journal_tmp"
        [ "$backup_created" -eq 0 ] || rm -f -- "$backup"
        unset 'ABLETON_TXN_SEEN[$seen_key]'
        return 1
    fi
}

ableton_txn_expect()
{
    local path="$1" post="$2" journal tmp status p backup old extra matches=0
    local current original next safe=1 write_ok=1
    [ -n "${ABLETON_TRANSACTION_DIR:-}" ] || return 0
    ableton_txn_object_token_valid "$post" || {
        ableton_config_error "invalid expected transaction object for $path"
        return 1
    }
    journal="$ABLETON_TRANSACTION_DIR/files.tsv"
    ableton_txn_validate_files "$ABLETON_TRANSACTION_DIR" || return 1
    current="$(ableton_object_token "$path" 2>/dev/null || true)"
    [ -n "$current" ] || {
        ableton_config_error "cannot read transaction destination before binding it: $path"
        return 1
    }
    tmp="$(mktemp "$ABLETON_TRANSACTION_DIR/.files.tsv.XXXXXX")" || return 1
    while IFS=$'\t' read -r status p backup old extra \
          || [ -n "$status$p$backup$old$extra" ]; do
        if [ "$p" = "$path" ]; then
            matches=$((matches + 1))
            old="${old:-pending}"
            if [ "$status" = present ]; then
                original="$(ableton_object_token "$backup" 2>/dev/null || true)"
            else
                original=absent
            fi
            if [ -z "$original" ] \
               || { [ "$current" != "$original" ] \
                    && ! ableton_txn_post_accepts "$old" "$current"; }; then
                safe=0
                continue
            fi
            if [ "$current" = "$post" ] || [ "$current" = "$original" ]; then
                next="$post"
            else
                next="$current,$post"
            fi
            printf '%s\t%s\t%s\t%s\n' "$status" "$p" "$backup" "$next" >> "$tmp" \
                || write_ok=0
        else
            printf '%s\t%s\t%s\t%s\n' "$status" "$p" "$backup" "${old:-pending}" >> "$tmp" \
                || write_ok=0
        fi
    done < "$journal"
    if [ "$safe" -ne 1 ] || [ "$write_ok" -ne 1 ]; then
        rm -f -- "$tmp"
        if [ "$safe" -ne 1 ]; then
            ableton_config_error "A file changed before the installer could finish updating it: $path"
        else
            ableton_config_error "could not prepare transaction state for $path"
        fi
        return 1
    fi
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

ableton_manifest_object_record()
{
    local path="$1" manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ -r "$manifest" ] || return 1
    awk -F '\t' -v p="$path" '
        $2==p && ($1=="file" || $1=="config" || $1=="symlink") {
            matches++
            record=$1 "\t" $3
        }
        END {
            if (matches == 1) print record
            else exit 1
        }
    ' "$manifest"
}

ableton_manifest_path_claimed()
{
    ableton_manifest_object_record "$1" >/dev/null
}

ableton_manifest_path_matches()
{
    local path="$1" record _kind expected actual
    record="$(ableton_manifest_object_record "$path")" || return 1
    IFS=$'\t' read -r _kind expected <<< "$record"
    actual="$(ableton_manifest_digest "$path" 2>/dev/null || true)"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

ableton_transaction_core_complete()
{
    local transaction="$1" marker="$1/core-complete"
    [ -d "$transaction" ] && [ ! -L "$transaction" ] \
        && [ -f "$marker" ] && [ ! -L "$marker" ] \
        && cmp -s -- "$marker" <(printf 'format=1\ncore=complete\n')
}

ableton_mark_transaction_core_complete()
{
    local transaction="$1" marker="$1/core-complete" tmp
    [ -d "$transaction" ] && [ ! -L "$transaction" ] || return 1
    tmp="$(mktemp "$transaction/.core-complete.XXXXXX")" || return 1
    if ! printf 'format=1\ncore=complete\n' > "$tmp" \
       || ! chmod 600 "$tmp" \
       || ! mv -T -f -- "$tmp" "$marker" \
       || ! ableton_transaction_core_complete "$transaction"; then
        rm -f -- "$tmp" 2>/dev/null || true
        return 1
    fi
}

ableton_install_state_has_active_transaction()
{
    local root="$ABLETON_STATE_HOME/transactions" marker markers transaction parent
    if [ -e "$root" ] || [ -L "$root" ]; then
        [ -d "$root" ] && [ ! -L "$root" ] || return 0
    else
        return 1
    fi
    # Component/coordinator transactions keep the marker at depth two;
    # prefix-host is a deliberately nested file journal at depth three.
    if ! markers="$(find "$root" -mindepth 2 -maxdepth 3 -name active -print 2>/dev/null)"; then
        # An unreadable recovery directory is not proof that installation work
        # is absent. Launchers fail closed here because starting Wine while a
        # core runtime/prefix recovery is unknown can damage the prefix.
        return 0
    fi
    [ -n "$markers" ] || return 1
    while IFS= read -r marker; do
        [ -n "$marker" ] || continue
        transaction="${marker%/active}"
        ableton_transaction_core_complete "$transaction" && continue
        # prefix-host is the file journal nested inside a full install.  Once
        # the parent records that its core result is complete, failure to remove
        # this child marker is optional recovery-file cleanup rather than an
        # unsafe Wine-prefix transaction.
        if [ "${transaction##*/}" = prefix-host ]; then
            parent="${transaction%/prefix-host}"
            ableton_transaction_core_complete "$parent" && continue
        fi
        return 0
    done <<< "$markers"
    return 1
}

ableton_live_desktop_entry_valid()
{
    local file="$1"
    [ -f "$file" ] && [ ! -L "$file" ] && ableton_file_has_no_nul "$file" || return 1
    [ "$(grep -c '^\[Desktop Entry\]$' "$file")" -eq 1 ] \
        && [ "$(grep -c '^Type=Application$' "$file")" -eq 1 ] \
        && [ "$(grep -c '^Name=.' "$file")" -eq 1 ] \
        && [ "$(grep -c '^Comment=Music production and performance$' "$file")" -eq 1 ] \
        && [ "$(grep -cF "Exec=$ABLETON_BIN_HOME/ableton-live %f" "$file")" -eq 1 ] \
        && [ "$(grep -Ec '^Icon=live-(beta|intro|lite|standard|suite)$' "$file")" -eq 1 ] \
        && [ "$(grep -Ec '^StartupWMClass=.+[.]exe$' "$file")" -eq 1 ] \
        && [ "$(grep -c '^MimeType=application/x-ableton-live-set;application/x-ableton-live-clip;application/x-ableton-live-pack;$' "$file")" -eq 1 ]
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
        ableton_config_error "the installed-file list is unsafe or unreadable: $manifest"
        return 1
    }
    ableton_file_has_no_nul "$manifest" || {
        ableton_config_error "the installed-file list contains invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r kind path detail extra || [ -n "$kind$path$detail$extra" ]; do
        if [ -n "$extra" ] || [ -z "$path" ] || ! ableton_manifest_path_ok "$path" \
           || [ -n "${seen[$path]+x}" ]; then
            ableton_config_error "the installed-file list is invalid or ambiguous"
            return 1
        fi
        seen["$path"]=1
        case "$kind" in
            file|config|symlink)
                ableton_managed_path_allowed "$kind" "$path" || {
                    ableton_config_error "the installed-file list contains an unexpected path: $path"
                    return 1
                }
                [[ "$detail" =~ ^[0-9a-f]{64}$ ]] || {
                    ableton_config_error "the installed-file list contains an invalid entry for $path"
                    return 1
                } ;;
            runtime)
                [ "$detail" = "$ABLETON_RUNTIME_NAME" ] || {
                    ableton_config_error "the installed-file list contains an invalid Wine entry"
                    return 1
                } ;;
            *)
                ableton_config_error "the installed-file list contains an unknown entry type"
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
        ableton_config_error "the list of saved earlier files is unsafe or unreadable: $index"
        return 1
    }
    ableton_file_has_no_nul "$index" || {
        ableton_config_error "the list of saved earlier files contains invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r status path backup extra || [ -n "$status$path$backup$extra" ]; do
        if [ -n "$extra" ] || [ "$status" != present ] || [ -z "$path" ] \
           || ! ableton_manifest_path_ok "$path" \
           || { ! ableton_managed_path_allowed file "$path" \
                && ! ableton_managed_path_allowed config "$path" \
                && ! ableton_managed_path_allowed symlink "$path"; } \
           || [ -n "${seen[$path]+x}" ]; then
            ableton_config_error "the list of saved earlier files is invalid or ambiguous"
            return 1
        fi
        expected="$ABLETON_STATE_HOME/install-prestate/$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
        if [ "$backup" != "$expected" ] \
           || { [ ! -f "$backup" ] && [ ! -L "$backup" ]; }; then
            ableton_config_error "the saved earlier copy is missing or misplaced for $path"
            return 1
        fi
        digest="$(ableton_manifest_digest "$backup" 2>/dev/null || true)"
        [ -n "$digest" ] || {
            ableton_config_error "the saved earlier copy is unreadable for $path"
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
        ableton_config_error "the saved file-opening settings are unsafe or unreadable"
        return 1
    }
    ableton_file_has_no_nul "$state" || {
        ableton_config_error "the saved file-opening settings contain invalid binary data"
        return 1
    }
    while IFS=$'\t' read -r type prior extra || [ -n "$type$prior$extra" ]; do
        [ -z "$extra" ] && [ -n "$type" ] && [ -z "${seen[$type]+x}" ] || {
            ableton_config_error "the saved file-opening settings are invalid or ambiguous"
            return 1
        }
        case "$type" in
            x-scheme-handler/ableton|application/x-wine-extension-auz|\
            application/x-ableton-live-set|application/x-ableton-live-clip|\
            application/x-ableton-live-pack|application/x-ableton-live-max-device|\
            x-scheme-handler/c74max) ;;
            *) ableton_config_error "the saved file-opening settings contain an unknown file type"; return 1 ;;
        esac
        [ -z "$prior" ] || [[ "$prior" =~ ^[A-Za-z0-9_.+-]+[.]desktop$ ]] || {
            ableton_config_error "the saved file-opening settings contain an invalid application"
            return 1
        }
        seen["$type"]=1
    done < "$state"
    return 0
}

ableton_validate_prestate_store()
{
    local index="$ABLETON_STATE_HOME/install-prestate.tsv"
    local backup_dir="$ABLETON_STATE_HOME/install-prestate" slot name expected count=0 indexed=0
    local slots_text=""
    local -A slots=()
    ableton_validate_prestate_index "$index" || return 1
    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
        [ -d "$backup_dir" ] && [ ! -L "$backup_dir" ] || {
            ableton_config_error "the directory holding saved earlier files is unsafe"
            return 1
        }
        if ! slots_text="$(find "$backup_dir" -mindepth 1 -maxdepth 1 -print)"; then
            ableton_config_error "the directory holding saved earlier files could not be checked"
            return 1
        fi
        if [ -n "$slots_text" ]; then
            while IFS= read -r slot; do
                name="${slot##*/}"
                [[ "$name" =~ ^[0-9a-f]{64}$ ]] \
                    && { [ -f "$slot" ] || [ -L "$slot" ]; } \
                    && [ -n "$(ableton_manifest_digest "$slot" 2>/dev/null || true)" ] || {
                    ableton_config_error "the directory holding saved earlier files contains an unsafe object"
                    return 1
                }
                slots["$name"]=1
                count=$((count + 1))
            done <<< "$slots_text"
        fi
    fi
    if [ -e "$index" ]; then
        while IFS=$'\t' read -r _ path _ _; do
            expected="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
            [ -n "${slots[$expected]+x}" ] || {
                ableton_config_error "the list of saved earlier files is incomplete"
                return 1
            }
            indexed=$((indexed + 1))
        done < "$index"
    fi
    [ "$count" -eq "$indexed" ] || {
        ableton_config_error "the directory holding saved earlier files contains an unlisted object"
        return 1
    }
}

ableton_validate_install_state_journals()
{
    local mode="${1:-strict}"
    case "$mode" in strict|repair) ;; *) return 1 ;; esac
    if [ "$mode" = strict ]; then
        ableton_validate_ownership_manifest \
            "$ABLETON_STATE_HOME/install-manifest.tsv" || return 1
    elif ! ableton_validate_ownership_manifest \
            "$ABLETON_STATE_HOME/install-manifest.tsv" >/dev/null 2>&1; then
        ui_status m_rebuilding_file_list
    fi
    # Repair rebuilds installer-generated files and their inventory. Saved
    # earlier files are relevant only when uninstall needs to restore them, so
    # stale optional restoration data cannot veto an otherwise safe repair.
    [ "$mode" = strict ] || return 0
    ableton_validate_prestate_store
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
            strings "$path" 2>/dev/null \
                | grep -F 'ableton-linkd: native Ableton Link session anchor and probe' >/dev/null ;;
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
        "$ABLETON_DATA_HOME/shortcut-hold.sh") grep -qF 'GNOME shortcut hold' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/check-ntsync.sh")
            grep -qF 'NT sync semantics hold' "$path" 2>/dev/null \
                || grep -qF 'ABLETON_REQUIRE_NTSYNC' "$path" 2>/dev/null ;;
        "$ABLETON_DATA_HOME/setsyscolors.exe"|"$ABLETON_DATA_HOME/learnheal.exe"|\
        "$ABLETON_DATA_HOME/ntsyncprobe.exe") return 1 ;;
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
    local target="$1" prestate_policy="${3:-preserve-local}"
    local index="$ABLETON_STATE_HOME/install-prestate.tsv" prestate_dir id backup
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    local index_tmp row_count recorded
    case "$prestate_policy" in
        preserve-local|replace-launcher|replace-generated) ;;
        *)
            ableton_config_error "The installer received an unknown pre-install backup policy: $prestate_policy"
            return 1 ;;
    esac
    if [ "$prestate_policy" = replace-generated ] \
       && ! ableton_replace_generated_path_allowed "$target"; then
        ableton_config_error "refusing the private-file overwrite policy outside Ableton's support directory: $target"
        return 1
    fi
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
    [ -e "$target" ] || [ -L "$target" ] || return 0

    # Launchers keep a displaced object beside the generated launcher. Other
    # files published from the installer payload are authoritative project
    # output. Both still receive an immediate transaction copy, so persistent
    # uninstall bookkeeping must not become a second publication gate.
    case "$prestate_policy" in replace-launcher|replace-generated) return 0 ;; esac

    # A path already listed by this invocation or by a structurally valid
    # installed-file list is ours to refresh. Its saved digest is uninstall
    # bookkeeping, not an installation integrity gate: updates replace the
    # generated file even if it was edited or an older digest is stale.
    if [ -n "${ABLETON_OWNED_KINDS[$target]+x}" ] \
       || { ableton_validate_ownership_manifest "$manifest" >/dev/null 2>&1 \
            && ableton_manifest_path_claimed "$target"; }; then
        return 0
    fi
    # Recognisable files from older releases are generated installer output too.
    # Repair them directly even if optional saved-copy metadata is stale.
    ableton_legacy_owned_path "$target" && return 0

    # Preserve the first object displaced at an otherwise unclaimed path. Later
    # repairs keep that original copy instead of replacing it with an installer
    # generation, so uninstall can restore the user's object exactly once.
    if [ -e "$index" ] || [ -L "$index" ]; then
        [ -f "$index" ] && [ ! -L "$index" ] && [ -r "$index" ] || {
            ableton_config_error "The saved copies of earlier files cannot be updated safely; the existing file was left at $target"
            return 1
        }
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")" \
            || return 1
        case "$row_count" in ''|*[!0-9]*) return 1 ;; esac
        if [ "$row_count" -gt 0 ]; then
            [ "$row_count" -eq 1 ] || {
                ableton_config_error "More than one saved earlier copy is listed for $target; the existing file was left unchanged"
                return 1
            }
            id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" || return 1
            recorded="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { print $3; exit }' "$index")" \
                || return 1
            backup="$ABLETON_STATE_HOME/install-prestate/$id"
            if [ "$recorded" = "$backup" ] \
               && { [ -f "$backup" ] || [ -L "$backup" ]; } \
               && [ -n "$(ableton_manifest_digest "$backup" 2>/dev/null || true)" ]; then
                return 0
            fi
            ableton_config_error "The saved earlier copy of $target cannot be used safely; the existing file was left unchanged"
            return 1
        fi
    fi
    # Only the optional saved-copy store is checked here. A damaged installed-
    # file list must never stop the installer from rebuilding generated files.
    ableton_validate_prestate_store || {
        ableton_config_error "The installer could not safely save the existing file at $target, so it was left unchanged"
        return 1
    }
    ableton_mark_state_home || return 1
    prestate_dir="$ABLETON_STATE_HOME/install-prestate"
    if [ -e "$prestate_dir" ] || [ -L "$prestate_dir" ]; then
        [ -d "$prestate_dir" ] && [ ! -L "$prestate_dir" ] || {
            ableton_config_error "The saved-copy directory is not safe to use; the existing file was left at $target"
            return 1
        }
    else
        mkdir -- "$prestate_dir" || return 1
    fi
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" || return 1
    backup="$prestate_dir/$id"
    [ ! -e "$backup" ] && [ ! -L "$backup" ] || {
        ableton_config_error "A saved copy already exists without a usable record for $target; the existing file was left unchanged"
        return 1
    }
    ableton_txn_snapshot "$index" || return 1
    ableton_txn_snapshot "$backup" || return 1
    index_tmp="$(mktemp "$ABLETON_STATE_HOME/.prestate.XXXXXX")" || return 1
    [ ! -e "$index" ] || cp -- "$index" "$index_tmp" \
        || { rm -f -- "$index_tmp"; return 1; }
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
    local mode="$1" source="$2" target="$3" kind="${4:-file}"
    local prestate_policy="${5:-preserve-local}" post tmp parent
    post="$(ableton_regular_source_token "$source")" || return 1
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "refusing to replace directory with a file: $target"
        return 1
    }
    ableton_persist_file_prestate "$target" "$source" "$prestate_policy" || return 1
    ableton_txn_snapshot "$target" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    parent="$(dirname "$target")" || return 1
    mkdir -p -- "$parent" || return 1
    tmp="$(mktemp "$parent/.ableton-install.XXXXXX")" || return 1
    if ! install -m "$mode" -- "$source" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$post" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    ableton_record_owned "$target" "$kind" || return 1
}

ableton_install_symlink()
{
    local link_text="$1" target="$2" prestate_policy="${3:-preserve-local}" post tmp parent
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "refusing to replace directory with a symlink: $target"
        return 1
    }
    ableton_persist_file_prestate "$target" "" "$prestate_policy" || return 1
    ableton_txn_snapshot "$target" || return 1
    post="$(ableton_symlink_text_token "$link_text")" || return 1
    ableton_txn_expect "$target" "$post" || return 1
    parent="$(dirname "$target")" || return 1
    mkdir -p -- "$parent" || return 1
    tmp="$(mktemp "$parent/.ableton-link.XXXXXX")" || return 1
    rm -f -- "$tmp" || return 1
    if ! ln -s -- "$link_text" "$tmp" \
       || [ "$(ableton_object_token "$tmp" 2>/dev/null || true)" != "$post" ] \
       || ! mv -T -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
    ableton_record_owned "$target" symlink || return 1
}

# Save the most recently displaced launcher object beside its path as
# <name>.bak. The transaction tracks both paths and restores both objects after
# a later failure. Persist each foreign object once before replacing either
# path, so uninstall can restore both the original launcher and a personal file
# that already occupied <name>.bak, even after later launcher updates.
ableton_backup_launcher()
{
    local target="$1" desired="$2" desired_mode="${3:-}" backup="$1.bak" current
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv"
    ableton_launcher_path_allowed "$target" || {
        ableton_config_error "launcher path falls outside the managed launcher set: $target"
        return 1
    }
    [ -e "$target" ] || [ -L "$target" ] || return 0
    [ ! -d "$target" ] || [ -L "$target" ] || {
        ableton_config_error "launcher path points to a directory: $target"
        return 1
    }
    [ -f "$target" ] || [ -L "$target" ] || {
        ableton_config_error "launcher path is not a regular file or symlink: $target"
        return 1
    }
    current="$(ableton_object_token "$target")" || return 1
    if [ "$current" = "$desired" ] \
       && { [ -z "$desired_mode" ] \
            || { [ ! -L "$target" ] && [ "$(stat -c '%a' -- "$target")" = "$desired_mode" ]; }; }; then
        return 0
    fi
    # Once both paths belong to an installed launcher pair, the adjacent copy
    # is the first displaced launcher, not scratch space for every generation.
    # Keep it unchanged while refreshing the canonical launcher; the active
    # transaction already protects the canonical path if this update fails.
    if { [ -n "${ABLETON_OWNED_KINDS[$target]+x}" ] \
         && [ -n "${ABLETON_OWNED_KINDS[$backup]+x}" ]; } \
       || { ableton_validate_ownership_manifest "$manifest" >/dev/null 2>&1 \
            && ableton_manifest_path_claimed "$target" \
            && ableton_manifest_path_claimed "$backup"; }; then
        return 0
    fi
    [ ! -d "$backup" ] || [ -L "$backup" ] || {
        ableton_config_error "launcher backup path points to a directory: $backup"
        return 1
    }
    if [ -e "$backup" ] && [ ! -f "$backup" ] && [ ! -L "$backup" ]; then
        ableton_config_error "launcher backup path is not a regular file or symlink: $backup"
        return 1
    fi
    ableton_persist_file_prestate "$backup" "" preserve-local || return 1
    ableton_txn_snapshot "$backup" || return 1
    ableton_txn_expect "$backup" "$current" || return 1
    ableton_atomic_restore_object "$target" "$backup" || return 1
    ableton_record_owned "$backup" "${current%%:*}"
}

ableton_launcher_claim_matches()
{
    local target="$1" current="$2"
    local record kind digest
    kind="${current%%:*}"
    if [ "${ABLETON_OWNED_KINDS[$target]-}" = "$kind" ]; then
        return 0
    fi
    record="$(ableton_manifest_object_record "$target")" || return 1
    IFS=$'\t' read -r kind digest <<< "$record"
    case "$kind" in file|symlink) ;; *) return 1 ;; esac
    [ "$current" = "$kind:$digest" ]
}

ableton_install_launcher_file()
{
    local mode="$1" source="$2" target="$3" kind="${4:-file}" desired
    desired="$(ableton_regular_source_token "$source")" || return 1
    ableton_backup_launcher "$target" "$desired" "$mode" || return 1
    ableton_install_file "$mode" "$source" "$target" "$kind" replace-launcher
}

ableton_install_launcher_symlink()
{
    local link_text="$1" target="$2" desired
    desired="$(ableton_symlink_text_token "$link_text")" || return 1
    ableton_backup_launcher "$target" "$desired" || return 1
    ableton_install_symlink "$link_text" "$target" replace-launcher
}

ableton_publish_file()
{
    if [ "$ABLETON_PUBLICATION_JOURNAL_BROKEN" -eq 1 ]; then
        ableton_publish_without_file_journal ableton_install_file "$@"
        return
    fi
    ableton_install_file "$@" || return 1
    ableton_txn_checkpoint_files
}

ableton_publish_launcher_file()
{
    if [ "$ABLETON_PUBLICATION_JOURNAL_BROKEN" -eq 1 ]; then
        ableton_publish_without_file_journal ableton_install_launcher_file "$@"
        return
    fi
    ableton_install_launcher_file "$@" || return 1
    ableton_txn_checkpoint_files
}

ableton_publish_launcher_symlink()
{
    if [ "$ABLETON_PUBLICATION_JOURNAL_BROKEN" -eq 1 ]; then
        ableton_publish_without_file_journal ableton_install_launcher_symlink "$@"
        return
    fi
    ableton_install_launcher_symlink "$@" || return 1
    ableton_txn_checkpoint_files
}

# Once optional recovery bookkeeping itself becomes unavailable, keep repairing
# independent files atomically instead of turning that bookkeeping into a gate.
# The caller still owns and later retires the surrounding core transaction.
ableton_publish_without_file_journal()
{
    local operation="$1" saved_transaction="${ABLETON_TRANSACTION_DIR:-}" rc
    shift
    ABLETON_TRANSACTION_DIR=""
    export ABLETON_TRANSACTION_DIR
    if "$operation" "$@"; then rc=0; else rc=$?; fi
    ABLETON_TRANSACTION_DIR="$saved_transaction"
    export ABLETON_TRANSACTION_DIR
    return "$rc"
}

# Project files are a fixed list of independent copies. A failed path does not
# stop later paths, and completed copies are never restored automatically.
ableton_prepare_project_backup_dir()
{
    local root stamp marker
    if [ -n "${ABLETON_PROJECT_BACKUP_DIR:-}" ]; then
        if [ -z "${ABLETON_PROJECT_BACKUP_STAMP:-}" ]; then
            ABLETON_PROJECT_BACKUP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
            export ABLETON_PROJECT_BACKUP_STAMP
        fi
        return 0
    fi
    root="$ABLETON_STATE_HOME/backups"
    marker="$ABLETON_STATE_HOME/.ableton-linux-state"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    mkdir -p -- "$root" || return 1
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        printf 'format=1\nowner=ableton-linux\n' > "$marker" 2>/dev/null || true
        chmod 600 "$marker" 2>/dev/null || true
    fi
    ABLETON_PROJECT_BACKUP_DIR="$(mktemp -d "$root/$stamp.XXXXXX")" || return 1
    ABLETON_PROJECT_BACKUP_STAMP="$stamp"
    export ABLETON_PROJECT_BACKUP_DIR ABLETON_PROJECT_BACKUP_STAMP
}

ableton_project_choice_marker()   # marker name: present or created in the run's backup dir
{
    local marker
    ableton_prepare_project_backup_dir || return 1
    marker="$ABLETON_PROJECT_BACKUP_DIR/$1"
    mkdir -- "$marker" 2>/dev/null || { [ -d "$marker" ] && [ ! -L "$marker" ]; }
}

# One question per installer run, at the first existing destination. 0 =
# overwrite (the default), 1 = keep every existing destination, 2 = abort,
# 3 = the overwrite choice could not be recorded for later processes.
ableton_project_overwrite_choice()
{
    local target="$1" run="${ABLETON_PROJECT_BACKUP_DIR:-}"
    if [ "$ABLETON_PROJECT_KEEP_ALL" -eq 1 ] \
       || { [ -n "$run" ] && [ -d "$run/.keep-all" ] && [ ! -L "$run/.keep-all" ]; }; then
        return 1
    fi
    [ "${ABLETON_PROJECT_ASSUME_YES:-0}" != 1 ] \
        && [ "$ABLETON_PROJECT_OVERWRITE_ALL" -ne 1 ] \
        && { [ -z "$run" ] || [ ! -d "$run/.overwrite-all" ] || [ -L "$run/.overwrite-all" ]; } \
        || return 0
    printf '%s exists.\n' "$target" >&2 || true
    ui_question q_overwrite_title o q_overwrite_all q_keep q_abort
    case "$UI_ANSWER" in
        k)
            ableton_project_choice_marker .keep-all || true
            ABLETON_PROJECT_KEEP_ALL=1
            ui_info q_keep_chosen
            return 1 ;;
        a)
            ui_info q_abort_chosen
            return 2 ;;
    esac
    if ! ableton_project_choice_marker .overwrite-all; then
        echo "!! $(ui_text m_overwrite_all_failed)" >&2 || true
        return 3
    fi
    ABLETON_PROJECT_OVERWRITE_ALL=1
    ui_info q_overwrite_chosen "$ABLETON_PROJECT_BACKUP_DIR"
    return 0
}

ableton_backup_project_destination()
{
    local target="$1" relative backup parent
    if ! ableton_prepare_project_backup_dir; then
        echo "!! backup failed; left destination untouched: $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 1
    fi
    relative="${target#/}"
    backup="$ABLETON_PROJECT_BACKUP_DIR/$relative.bak-$ABLETON_PROJECT_BACKUP_STAMP"
    parent="$(dirname -- "$backup")" || return 1
    if ! mkdir -p -- "$parent"; then
        echo "!! backup failed; left destination untouched: $target -> $backup" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 1
    fi
    if ! mv -T -- "$target" "$backup"; then
        echo "!! backup failed; left destination untouched: $target -> $backup" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 1
    fi
    ABLETON_OPTIONAL_FILES_BACKED_UP=$((ABLETON_OPTIONAL_FILES_BACKED_UP + 1))
    printf '   backup: %s\n' "$backup" || true
}

ableton_prepare_project_destination()
{
    local source="$1" target="$2" choice parent
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] || return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        if ableton_project_overwrite_choice "$target"; then
            choice=0
        else
            choice=$?
        fi
        case "$choice" in
            0) ableton_backup_project_destination "$target" || return 1 ;;
            1)
                ABLETON_OPTIONAL_FILES_KEPT=$((ABLETON_OPTIONAL_FILES_KEPT + 1))
                ui_status m_kept_file "$target"
                return 1 ;;
            2)
                ABLETON_OPTIONAL_FILE_CANCELLED=1
                echo "!! cancelled before replacing $target" >&2 || true
                return 1 ;;
            3)
                ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
                return 1 ;;
        esac
    fi
    parent="$(dirname -- "$target")" || return 1
    if ! mkdir -p -- "$parent"; then
        echo "!! copy failed: $source -> $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 1
    fi
}

ableton_install_project_file()
{
    local mode="$1" source="$2" target="$3"
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] || return 0
    if [ ! -f "$source" ]; then
        echo "!! copy failed: $source -> $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 0
    fi
    ableton_prepare_project_destination "$source" "$target" || return 0
    if ! cp -- "$source" "$target"; then
        echo "!! copy failed: $source -> $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    elif ! chmod "$mode" "$target"; then
        echo "!! chmod failed: $target (mode $mode)" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    elif [ "${ABLETON_RECORD_PROJECT_FILES:-0}" = 1 ] \
       && ! ableton_record_owned "$target" file; then
        echo "!! ownership record failed: $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    fi
    return 0
}

ableton_install_project_symlink()
{
    local source="$1" target="$2"
    [ "$ABLETON_OPTIONAL_FILE_CANCELLED" -eq 0 ] || return 0
    if [ ! -e "$source" ] && [ ! -L "$source" ]; then
        echo "!! copy failed: $source -> $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
        return 0
    fi
    ableton_prepare_project_destination "$source" "$target" || return 0
    if ! ln -s -- "$source" "$target"; then
        echo "!! copy failed: $source -> $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    elif [ "${ABLETON_RECORD_PROJECT_FILES:-0}" = 1 ] \
       && ! ableton_record_owned "$target" symlink; then
        echo "!! ownership record failed: $target" >&2 || true
        ABLETON_OPTIONAL_FILE_FAILURES=$((ABLETON_OPTIONAL_FILE_FAILURES + 1))
    fi
    return 0
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
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" || return 1
    backup="$ABLETON_STATE_HOME/install-prestate/$id"
    if [ -r "$index" ]; then
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")" \
            || return 1
        present_count="$(awk -F '\t' -v p="$target" \
            '$1=="present" && $2==p { n++ } END { print n+0 }' "$index")" || return 1
        recorded="$(awk -F '\t' -v p="$target" \
            '$1=="present" && $2==p { print $3; exit }' "$index")" || return 1
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
    if [ -n "$recorded" ]; then
        ableton_txn_snapshot "$index" || return 1
        ableton_txn_snapshot "$backup" || return 1
        # atomic_restore replaces the managed object directly. Removing it first
        # creates an installer-owned third state that neither the original nor
        # final journal token can authorize if the restore then fails.
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
        ui_status pa_restored_previous "$target"
    else
        rm -f -- "$target" || return 1
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
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
    id="$(printf '%s' "$target" | sha256sum | awk '{print $1}')" || return 1
    backup="$ABLETON_STATE_HOME/install-prestate/$id"
    if [ -r "$index" ]; then
        row_count="$(awk -F '\t' -v p="$target" '$2==p { n++ } END { print n+0 }' "$index")" \
            || return 1
        recorded="$(awk -F '\t' -v p="$target" '$1=="present" && $2==p { print $3; exit }' "$index")" \
            || return 1
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

ableton_write_ownership_manifest()
{
    # This file is an uninstall inventory, not installation integrity state.
    # It is deliberately outside component/prefix journals: if it is stale or
    # malformed, rebuild it from this invocation instead of rejecting working
    # runtime or prefix changes. The optional transaction argument remains for
    # compatibility with older callers but no longer changes publication.
    [ "$#" -le 1 ] || return 1
    local manifest="$ABLETON_STATE_HOME/install-manifest.tsv" tmp kind path digest
    ableton_mark_state_home || return 1
    tmp="$(mktemp "$ABLETON_STATE_HOME/.manifest.XXXXXX")" || return 1
    # Preserve records for components this invocation did not touch. Touched
    # paths are replaced below by their new digest. Runtime ownership is a
    # singleton, so every historical runtime row is retired before the
    # configured runtime is appended below.
    if [ -f "$manifest" ] && [ ! -L "$manifest" ] \
       && ableton_validate_ownership_manifest "$manifest" >/dev/null 2>&1; then
        while IFS=$'\t' read -r kind path digest; do
            case "$kind" in file|config|symlink) ;; *) continue ;; esac
            [ -n "$path" ] || continue
            [ -z "${ABLETON_MANIFEST_TOUCHED[$path]+x}" ] || continue
            printf '%s\t%s\t%s\n' "$kind" "$path" "$digest" >> "$tmp" \
                || { rm -f -- "$tmp"; return 1; }
        done < "$manifest"
    fi
    for path in "${ABLETON_OWNED_PATHS[@]}"; do
        [ -z "${ABLETON_MANIFEST_DEOWNED[$path]+x}" ] || continue
        [ -f "$path" ] || [ -L "$path" ] || continue
        digest="$(ableton_manifest_digest "$path")" \
            || { rm -f -- "$tmp"; return 1; }
        printf '%s\t%s\t%s\n' "${ABLETON_OWNED_KINDS[$path]:-file}" "$path" "$digest" >> "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
    done
    if [ "${ABLETON_RUNTIME_INSTALLED:-0}" -eq 1 ]; then
        printf 'runtime\t%s\t%s\n' "$ABLETON_WINE_ROOT" "$ABLETON_RUNTIME_NAME" >> "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
    fi
    if ! sort -u "$tmp" -o "$tmp" \
       || ! chmod 600 "$tmp" \
       || ! ableton_validate_ownership_manifest "$tmp" \
       || ! mv -T -f -- "$tmp" "$manifest"; then
        rm -f -- "$tmp"
        return 1
    fi
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
