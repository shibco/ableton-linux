# shellcheck shell=bash
# Sourceable theme detection helpers.
# ableton_detect_theme prints "dark" or "light" or returns 1 when no probe answers
# (probes: XDG settings portal via gdbus, busctl, then dbus-send — each tried
# until one answers — then GNOME gsettings).
# ableton_detect_topbar_colors <dark|light> prints the host titlebar colors as
# "R G B|R G B" (background|text) or returns 1 when the scheme argument is unusable.
# ableton_ask_color and ableton_live_theme_file read Ableton Live's own theme
# (.ask) files, for coloring the win32 chrome like Live's surface.

_adt_portal() {
    local out val=""
    if command -v gdbus >/dev/null 2>&1; then
        # serializes as "(<<uint32 1>>,)"
        out="$(timeout 5 gdbus call --session \
            --dest org.freedesktop.portal.Desktop \
            --object-path /org/freedesktop/portal/desktop \
            --method org.freedesktop.portal.Settings.Read \
            org.freedesktop.appearance color-scheme 2>/dev/null)" &&
            val="$(printf '%s\n' "$out" | grep -oE 'uint32 [0-9]+' | awk '{print $2; exit}')"
    fi
    if [ -z "$val" ] && command -v busctl >/dev/null 2>&1; then
        # replies "v v u 1"
        out="$(timeout 5 busctl --user call org.freedesktop.portal.Desktop \
            /org/freedesktop/portal/desktop org.freedesktop.portal.Settings Read \
            ss org.freedesktop.appearance color-scheme 2>/dev/null)" &&
            val="$(printf '%s\n' "$out" | awk '{print $NF; exit}' | grep -xE '[0-9]+')"
    fi
    if [ -z "$val" ] && command -v dbus-send >/dev/null 2>&1; then
        # replies "   variant       variant          uint32 1"
        out="$(timeout 5 dbus-send --session --print-reply \
            --dest=org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop \
            org.freedesktop.portal.Settings.Read \
            string:org.freedesktop.appearance string:color-scheme 2>/dev/null)" &&
            val="$(printf '%s\n' "$out" | grep -oE 'uint32 [0-9]+' | awk '{print $2; exit}')"
    fi
    case "$val" in ''|*[!0-9]*) return 1 ;; esac
    # 0 = no preference, 1 = prefer dark, 2 = prefer light
    case "$val" in
        1) echo dark ;;
        *) echo light ;;
    esac
}

_adt_gsettings() {
    command -v gsettings >/dev/null 2>&1 || return 1
    local scheme
    scheme="$(timeout 5 gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" || return 1
    case "$scheme" in
        *prefer-dark*)            echo dark ;;
        *prefer-light*|*default*) echo light ;;
        *)                        return 1 ;;
    esac
}

ableton_detect_theme() {
    local theme
    for probe in _adt_portal _adt_gsettings; do
        if theme="$($probe)"; then
            printf '%s\n' "$theme"
            return 0
        fi
    done
    return 1
}

# "r,g,b" (kdeglobals color entry) -> "R G B" (win32 [Control Panel\Colors] form),
# rejecting anything that is not three 0-255 components.
_adt_rgb() {
    local r g b rest c
    IFS=, read -r r g b rest <<< "$1"
    [ -z "$rest" ] || return 1
    for c in "$r" "$g" "$b"; do
        case "$c" in ""|*[!0-9]*) return 1 ;; esac
        [ "$c" -le 255 ] || return 1
    done
    printf '%s %s %s\n' "$r" "$g" "$b"
}

_adt_kdeglobals_key() {   # section key -> raw value
    awk -v sect="[$1]" -v key="$2=" '
        $0 == sect { f=1; next }
        /^\[/ { f=0 }
        f && index($0, key) == 1 { print substr($0, length(key) + 1); exit }
    ' "${XDG_CONFIG_HOME:-$HOME/.config}/kdeglobals" 2>/dev/null
}

# KDE: the window decoration takes its colors from the color scheme's Header set
# (Plasma 5.25+), with the legacy [WM] entries as the older spelling.
_adtc_kde() {
    local sect bg fg
    for sect in "Colors:Header BackgroundNormal ForegroundNormal" \
                "WM activeBackground activeForeground"; do
        set -- $sect
        bg="$(_adt_kdeglobals_key "$1" "$2")" || continue
        fg="$(_adt_kdeglobals_key "$1" "$3")" || continue
        bg="$(_adt_rgb "$bg")" || continue
        fg="$(_adt_rgb "$fg")" || continue
        printf '%s|%s\n' "$bg" "$fg"
        return 0
    done
    return 1
}

# GNOME draws Wine's titlebars in mutter-x11-frames with the stock GTK4/libadwaita
# header-bar colors; there is no settings surface to read them from, so these are
# those stylesheet constants per scheme. They double as the generic fallback.
_adtc_scheme_constants() {
    case "$1" in
        dark)  printf '48 48 48|255 255 255\n' ;;
        light) printf '255 255 255|51 51 51\n' ;;
        *)     return 1 ;;
    esac
}

ableton_detect_topbar_colors() {   # dark|light -> "R G B|R G B" (titlebar bg|fg)
    local colors
    if colors="$(_adtc_kde)"; then
        printf '%s\n' "$colors"
        return 0
    fi
    _adtc_scheme_constants "$1"
}

# Live theme (.ask) helpers. A theme is flat XML: <Key Value="#rrggbb" /> with an
# optional trailing alpha byte on 8-digit values.

ableton_ask_color() {   # <ask-file> <key> -> "R G B"
    local hex
    hex="$(sed -n 's/.*<'"$2"' Value="#\([0-9a-fA-F]\{6\}[0-9a-fA-F]\{0,2\}\)".*/\1/p' "$1" 2>/dev/null | head -n 1)"
    [ -n "$hex" ] || return 1
    hex="${hex:0:6}"
    printf '%d %d %d\n' $(( 16#${hex:0:2} )) $(( 16#${hex:2:2} )) $(( 16#${hex:4:2} ))
}

# ableton_live_theme_file <wineprefix> <install-themes-dir> <live-major> <dark|light>
# prints the .ask Live renders with. Preferences.cfg is an opaque binary whose
# values are not anchored to their tags, but a picked theme is stored as its plain
# name ("Catppuccin Auto"), so the newest cfg's UTF-16 strings (via `strings`,
# binutils) are matched against the themes actually installed — the factory Themes
# dir and the User Library — and the last match wins. No match (the stock Default
# theme, or no binutils) falls back to the follow-system default pair; the Tone and
# Contrast variant enums are not recoverable from the binary, so default-theme
# users get Neutral Medium. ABLETON_TOPBAR_MODE=system or a hex pair overrides.
ableton_live_theme_file() {
    local prefix="$1" themes="$2" major="$3" scheme="$4" prefs line drive cand d file=""
    local -a dirs
    dirs=("$themes")
    for d in "$prefix"/drive_c/users/*/Documents/Ableton/"User Library"/Themes; do
        [ -d "$d" ] && dirs+=("$d")
    done
    prefs="$(ls -d "$prefix"/drive_c/users/*/AppData/Roaming/Ableton/"Live ${major:-}"*/Preferences 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$prefs" ] && [ -r "$prefs/Preferences.cfg" ] && command -v strings >/dev/null 2>&1; then
        while IFS= read -r line; do
            case "$line" in
                [A-Za-z]:*.ask)   # full windows path -> through the prefix's dosdevices
                    drive="${line:0:1}"
                    cand="$prefix/dosdevices/${drive,,}:$(printf '%s\n' "${line:2}" | tr '\\' '/')"
                    [ -r "$cand" ] && file="$cand" ;;
                *)
                    for d in "${dirs[@]}"; do
                        if [ -r "$d/$line.ask" ]; then file="$d/$line.ask"; break
                        elif [ -r "$d/$line" ] && [ "${line##*.}" = ask ]; then file="$d/$line"; break
                        fi
                    done ;;
            esac
        done < <(strings -e l "$prefs/Preferences.cfg" 2>/dev/null)
    fi
    if [ -z "$file" ]; then
        case "$scheme" in
            dark)  line="Default Dark Neutral Medium.ask" ;;
            light) line="Default Light Neutral Medium.ask" ;;
            *)     return 1 ;;
        esac
        [ -r "$themes/$line" ] && file="$themes/$line"
    fi
    [ -n "$file" ] || return 1
    printf '%s\n' "$file"
}
