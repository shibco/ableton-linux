#!/usr/bin/env bash
# Opt-in payload removal used by --low-fi-ableton.

ableton_low_fi_remove_path()
{
    local prefix="$1" target="$2" resolved
    [ -e "$target" ] || [ -L "$target" ] || return 0
    resolved="$(readlink -f -- "$target")" || return 1
    case "$resolved" in "$prefix"/*) ;; *)
        echo "!! low-fi removal target escaped the prefix: $target" >&2
        return 1 ;;
    esac
    [ "$resolved" = "$target" ] || {
        echo "!! low-fi removal refuses symlinks: $target" >&2
        return 1
    }
    if [ -d "$target" ]; then
        rm -rf -- "$target"
    else
        rm -f -- "$target"
    fi
}

ableton_low_fi_remove()
{
    local prefix="$1" base live resources user target
    [ -n "$prefix" ] && [[ "$prefix" = /* ]] && [ "$prefix" != / ] \
        && [ -d "$prefix" ] && [ ! -L "$prefix" ] \
        && [ "$(readlink -f -- "$prefix")" = "$prefix" ] || {
            echo "!! low-fi removal needs a canonical Wine prefix" >&2
            return 1
        }

    base="$prefix/drive_c/ProgramData/Ableton"
    if [ -d "$base" ] && [ ! -L "$base" ]; then
        for live in "$base"/Live\ *; do
            [ -d "$live" ] || continue
            [ ! -L "$live" ] || {
                echo "!! low-fi removal refuses symlinks: $live" >&2
                return 1
            }
            resources="$live/Resources"
            if [ -d "$resources" ] && [ ! -L "$resources" ]; then
                # Factory Max devices are bundled below Resources. User Library
                # devices live elsewhere and are deliberately untouched.
                find -P "$resources" -type f -iname '*.amxd' -delete || return 1
            fi
            for target in \
                "$resources/Max" \
                "$live/Program/WebView2Loader.dll" \
                "$live/Redist/MicrosoftEdgeWebview2Setup.exe" \
                "$live/Redist/MicrosoftEdgeWebView2Setup.exe"; do
                ableton_low_fi_remove_path "$prefix" "$target" || return 1
            done
        done
    fi

    # Remove the shared evergreen runtime and updater installed into this prefix.
    # Standalone Max and third-party fixed WebView2 runtimes use other paths.
    for target in \
        "$prefix/drive_c/Program Files/Microsoft/EdgeWebView" \
        "$prefix/drive_c/Program Files/Microsoft/EdgeCore" \
        "$prefix/drive_c/Program Files/Microsoft/EdgeUpdate" \
        "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeWebView" \
        "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeCore" \
        "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeUpdate" \
        "$prefix/drive_c/ProgramData/Microsoft/EdgeUpdate"; do
        ableton_low_fi_remove_path "$prefix" "$target" || return 1
    done

    if [ -d "$prefix/drive_c/users" ] && [ ! -L "$prefix/drive_c/users" ]; then
        for user in "$prefix"/drive_c/users/*; do
            [ -d "$user" ] && [ ! -L "$user" ] || continue
            ableton_low_fi_remove_path "$prefix" \
                "$user/AppData/Local/Microsoft/EdgeUpdate" || return 1
            ableton_low_fi_remove_path "$prefix" \
                "$user/AppData/Local/Ableton/Cache/WebView2" || return 1
        done
    fi
}
