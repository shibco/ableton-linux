#!/bin/sh
# Ableton-on-Wine single-file installer (self-extracting).
# Usage:  sh ableton-wine-setup-@VERSION@.run [options]
# Options:
#   --runtime-only   install the patched Wine only; skip making the Wine prefix
#   --update         update compatibility files; keep Live, authorization, and projects
#   --no-launch      never run the Ableton installer (zip/exe) automatically
#   --no-link        skip Ableton Link setup (remembered on later runs)
#   --link           configure Ableton Link even if previously skipped or declined
#   --extract DIR    unpack this installer's files into DIR and exit
#   --uninstall      remove the installed Wine, launcher, and menu entries
#   --prefix         with --uninstall: also delete the Wine prefix and Live
#   --help           this text
# Environment:
#   ABLETON_DPI_MODE    auto|preserve|100|fractional|dpi<N> (overrides scale auto-detection)
#   ABLETON_THEME_MODE  auto|dark|light|preserve (overrides the light/dark sync)
#   ABLETON_LIVE_VERSION  11|12 (prepare the prefix for this Live version; default 12)
# Everything after the marker line is a tar archive; this header never changes it.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
# Tool output is parsed below (sha256sum, readelf, ldd); localised output
# breaks the checks (issue #36). C.UTF-8, never plain C: wine inherits this
# environment, and under a non-UTF-8 locale it cannot create the non-ASCII
# filenames Live's Max content ships, which kills the Ableton installer
# (issues #51, #55). glibc 2.35+, the floor checked below, always has C.UTF-8.
export LC_ALL=C.UTF-8

VERSION="@VERSION@"
PAYLOAD_SHA="@PAYLOAD_SHA@"
RUNTIME_NAME="wine-d2d1-nspa-11.13"

self="$(readlink -f -- "$0")"
stick_dir="$(dirname -- "$self")"

say()  { printf '%s\n' "$*"; }
fail() { printf '!! %s\n' "$*" >&2; exit 1; }

mode=install
do_launch=1
do_link_setup=1
do_link_force=0
extract_dir=""
drop_prefix=0
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)      head -18 "$self" | sed -n '2,18{s/^# \{0,1\}//;p}'; exit 0 ;;
        --runtime-only) mode=runtime ;;
        --update)       mode=update ;;
        --no-launch)    do_launch=0 ;;
        --no-link)      do_link_setup=0 ;;
        --link)         do_link_setup=1; do_link_force=1 ;;
        --uninstall)    mode=uninstall ;;
        --prefix)       drop_prefix=1 ;;
        --extract)      mode=extract; extract_dir="${2:?--extract needs a directory}"; shift ;;
        *)              fail "unknown option: $1 (try --help)" ;;
    esac
    shift
done

if [ "$drop_prefix" = 1 ] && [ "$mode" != uninstall ]; then
    fail "--prefix only applies with --uninstall"
fi

say "== Ableton-on-Wine installer $VERSION =="

# --- offer an in-place update when an installation is already here ------------
# Rerunning the full install always worked (dated rollbacks throughout), but it
# demands an Ableton download and walks every prompt again; update mode brings
# runtime, launcher, and prefix policy to this kit's version. It preserves the
# Live installation, authorization, and projects; compatibility settings may
# change.
if [ "$mode" = install ] && [ -x "$HOME/.local/opt/$RUNTIME_NAME/bin/wine" ] \
   && [ -f "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}/system.reg" ]; then
    installed_ver="$(cat "$HOME/.local/share/ableton-wine/VERSION" 2>/dev/null || true)"
    say ""
    say "An existing installation was found${installed_ver:+ (version $installed_ver)}."
    if [ -t 0 ]; then
        printf 'Update it to %s? Live, authorization, and projects are kept; compatibility settings may change. [Y/n] ' "$VERSION"
        read -r ans || ans=""
        case "$ans" in
            [Nn]*) say "-- full install it is; the existing runtime gets a dated rollback" ;;
            *)     mode=update ;;
        esac
    else
        say "-- updating it to $VERSION (Live, authorization, and projects are kept; compatibility settings may change)"
        mode=update
    fi
fi

# --- find the Ableton payload next to this file, up front ---------------------
# Any edition (Intro/Lite/Standard/Suite/Trial) and any major version works:
# an ableton_live*.zip straight from ableton.com, or an already-unpacked installer .exe.
find_live_payload() {
    live_payloads=()
    local f base
    for f in "$stick_dir"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        case "$base" in
            ableton_live*.zip|*ableton*.exe|*live*.exe) live_payloads+=("$f") ;;
        esac
    done
    [ "${#live_payloads[@]}" -le 1 ] || \
        mapfile -t live_payloads < <(printf '%s\n' "${live_payloads[@]}" | sort -V)
}
choose_live_payload() {    # picks one of live_payloads into live_exe or live_zip
    live_exe=""; live_zip=""
    local n="${#live_payloads[@]}" pick ans i
    [ "$n" -gt 0 ] || return 0
    if [ "$n" -eq 1 ]; then
        pick="${live_payloads[0]}"
    elif [ -t 0 ]; then
        say ""
        say "More than one Ableton download is next to this file:"
        i=1
        for pick in "${live_payloads[@]}"; do say "  $i) $(basename "$pick")"; i=$((i+1)); done
        while :; do
            printf 'Which one should be installed? [1-%s, Enter = %s] ' "$n" "$n"
            read -r ans || ans=""
            [ -n "$ans" ] || ans="$n"
            case "$ans" in
                *[!0-9]*) ;;
                *) [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ] && break ;;
            esac
            say "Please answer with a number between 1 and $n."
        done
        pick="${live_payloads[$((ans-1))]}"
    else
        pick="${live_payloads[$((n-1))]}"
        say "-- several Ableton downloads found; picking the newest: $(basename "$pick")"
    fi
    case "$(basename "$pick" | tr '[:upper:]' '[:lower:]')" in
        *.zip) live_zip="$pick" ;;
        *)     live_exe="$pick" ;;
    esac
}
manual_install=1
if [ "$mode" = install ] && [ "$do_launch" -eq 1 ]; then
    find_live_payload
    choose_live_payload
    if [ -z "$live_exe$live_zip" ] && [ -t 0 ]; then
        say ""
        say "No Ableton installer found next to this file"
        say "(looked for an ableton_live*.zip of any edition, or an Ableton .exe, in $stick_dir)."
        say "Put it here and press Enter. Or press Enter without it, and the"
        say "manual install commands are printed at the end."
        printf '> '
        read -r _ || true
        find_live_payload
        choose_live_payload
    fi
    if [ -n "$live_exe$live_zip" ]; then
        manual_install=0
        say "-- will install: $(basename "${live_exe:-$live_zip}")"
    fi
fi

# --- unpack the embedded kit ------------------------------------------------
workdir="$(mktemp -d "${TMPDIR:-/tmp}/ableton-setup.XXXXXX")"
cleanup() {
    rc=$?
    if [ "$rc" -eq 0 ]; then rm -rf "$workdir"
    else say "(kept $workdir for inspection; the failure details are above)"; fi
    exit "$rc"
}
trap cleanup EXIT

offset="$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$self")"
[ -n "$offset" ] || fail "this installer file is incomplete: copy or download the .run file again"
say "-- checking the installer's own files and unpacking them"
tail -n +"$offset" "$self" > "$workdir/payload.tar"
actual="$(sha256sum "$workdir/payload.tar" | awk '{print $1}')"
[ "$actual" = "$PAYLOAD_SHA" ] || fail "this installer file failed its integrity check (it was probably damaged while copying); copy the .run file again and retry"
kit="$workdir/kit"
mkdir -p "$kit"
tar -xf "$workdir/payload.tar" -C "$kit"
rm -f "$workdir/payload.tar"

# Setup versions 1 and 2 installed this hook as root. Declined installs
# never run setup-link.sh, which would remove it, and --no-link promises no
# sudo prompt, so on those paths only point at the leftover.
warn_stale_link_hook() {
    local hook=/etc/NetworkManager/dispatcher.d/50-link-multicast
    if [ -e "$hook" ]; then
        say "   note: an earlier Link setup installed $hook"
        say "   it is no longer used; remove it with: sudo rm $hook"
    fi
}

configure_link() {
    local marker="$HOME/.local/share/ableton-wine/link-configured"
    # The version is owned by setup-link.sh; a marker recording anything else
    # forces one re-run so existing installs pick up changed behavior.
    local required_version
    required_version="$(sed -n 's/^LINK_SETUP_VERSION=//p' "$kit/scripts/setup-link.sh")"

    if [ "$do_link_setup" -eq 0 ]; then
        say "-- Ableton Link setup skipped (--no-link)"
        # The decline is sticky, even over an earlier configured state: later
        # updates stay quiet until --link opts back in, which re-runs the
        # idempotent setup in full, so nothing is lost by recording it.
        # Record the configured baseline, not this kit's required version:
        # setup-link.sh reads the marker as prior_version and keys its
        # one-time migrations off it, so a version whose migration never ran
        # must not be written here.
        # Keep an already-recorded numeric baseline even when the marker is
        # already declined. Otherwise repeated --no-link updates turn
        # configured 5 -> declined 5 -> declined 0 and a later --link can
        # mistake a deliberate post-v5 enablement for a legacy one.
        local baseline
        baseline="$(sed -n 2p "$marker" 2>/dev/null || true)"
        case "$baseline" in ''|*[!0-9]*) baseline=0 ;; esac
        mkdir -p "$(dirname "$marker")" 2>/dev/null || true
        printf 'declined\n%s\n' "$baseline" > "$marker" 2>/dev/null || true
        warn_stale_link_hook
        return 0
    fi

    if [ -f "$marker" ] && [ "$do_link_force" -ne 1 ]; then
        local state ver
        state="$(sed -n 1p "$marker")"
        ver="$(sed -n 2p "$marker")"
        if [ "$state" = declined ]; then
            say "-- Ableton Link setup was previously declined (--no-link); pass --link to configure it now"
            warn_stale_link_hook
            return 0
        fi
        if [ -n "$required_version" ] && [ "$ver" = "$required_version" ]; then
            say "-- Ableton Link is already configured"
            return 0
        fi
    fi

    say "-- configuring Ableton Link"
    say "   This asks for sudo only to open UDP port 20808 in an active firewall"
    say "   and to remove what earlier setup versions installed under /etc."
    if bash "$kit/scripts/setup-link.sh"; then
        return 0
    fi

    say "!! Ableton Link was not configured; Live installation will continue."
    say "!! Close Live and run ~/.local/share/ableton-wine/setup-link.sh to retry."
    return 0
}

if [ "$mode" = extract ]; then
    mkdir -p "$extract_dir"
    cp -a "$kit/." "$extract_dir/"
    say "OK: kit extracted to $extract_dir"
    exit 0
fi
if [ "$mode" = uninstall ]; then
    if [ "$drop_prefix" = 1 ]; then
        bash "$kit/scripts/uninstall.sh" --prefix
    else
        bash "$kit/scripts/uninstall.sh"
    fi
    exit 0
fi

# --- host checks -------------------------------------------------------------
say "-- checking this machine"
[ "$(uname -m)" = x86_64 ] || fail "this installer needs a 64-bit Intel/AMD machine (x86_64); this machine is $(uname -m)"
command -v tar  >/dev/null || fail "the 'tar' program is missing: install it with your package manager, then rerun"
command -v zstd >/dev/null || fail "the 'zstd' program is missing (package name: zstd): install it, then rerun; it unpacks the Wine files"
glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
if [ -n "$glibc" ]; then
    case "$glibc" in
        2.[0-2]?|2.3[0-4]) fail "glibc $glibc is too old (need 2.35+, i.e. a 2022-or-newer distribution)" ;;
    esac
    say "   glibc $glibc: ok"
fi
# no grep -q: under pipefail it SIGPIPEs ldconfig and falsely fires this warning
if ! ldconfig -p 2>/dev/null | grep 'libpipewire-0\.3\.so\.0' >/dev/null; then
    say "   WARNING: one sound-system piece is missing: the PipeWire client library."
    say "   Everything will install fine, but Live will have NO SOUND until you"
    say "   add it (package: pipewire, 0.3.56 or newer). Nearly every 2023+ distro"
    say "   ships it by default; the Steam Deck already has it."
fi
# Bundled static cabextract covers machines that lack the host package.
if ! command -v cabextract >/dev/null; then
    say "   this machine has no 'cabextract'; using the copy bundled in this installer"
fi
export PATH="$kit/bin:$PATH"

# --- update an existing installation ------------------------------------------
if [ "$mode" = update ]; then
    say "-- updating the patched Wine (a dated rollback of the old runtime is kept)"
    bash "$kit/scripts/install.sh"
    configure_link
    say "-- refreshing the Wine prefix (registry policy + runtime DLL healing; compatibility settings may change)"
    bash "$kit/scripts/setup-prefix.sh" --refresh
    say ""
    say "================================================================"
    say "Done: updated to $VERSION. Ableton Live itself was not touched."
    say "Launch Live:   ~/.local/bin/ableton-live"
    say "================================================================"
    exit 0
fi

# --- install the runtime ------------------------------------------------------
say "-- installing the patched Wine (goes to ~/.local/opt, touches nothing else)"
bash "$kit/scripts/install.sh"
[ "$mode" = runtime ] && { say "OK: the patched Wine is installed (--runtime-only: stopped before creating the Wine prefix)"; exit 0; }
configure_link

# --- create the prefix --------------------------------------------------------
# Seed ABLETON_DPI_MODE from the detected display scale; the launcher re-detects on every start.
if [ -z "${ABLETON_DPI_MODE:-}" ]; then
    . "$kit/scripts/detect-scale.sh"
    detected="$(ableton_detect_scale_ex)" || detected=""
    scale=""; family=""
    if [ -n "$detected" ]; then
        scale="${detected% *}"; family="${detected#* }"
    fi
    if block="$(ableton_dpi_block_for_scale "$scale" "$family")"; then
        export ABLETON_DPI_MODE="$block"
        say "-- display scale: $(awk -v s="$scale" 'BEGIN { printf "%d", s*100 + 0.5 }')% (auto-detected)"
    elif [ -d "$HOME/.wine-ableton" ]; then
        export ABLETON_DPI_MODE=preserve
        say "-- display scale: ${scale:-could not be detected}${scale:+ (outside the calibrated 100-250% range)}; keeping your existing display settings"
    else
        export ABLETON_DPI_MODE=100
        say "-- display scale: ${scale:-could not be detected}${scale:+ (outside the calibrated 100-250% range)}; starting the new prefix at 100%"
        say "   (the launcher re-checks your display on every start, so this corrects itself)"
    fi
fi
say "-- creating the Wine prefix, Live's private 'C: drive' at ~/.wine-ableton"
say "   (fonts and runtime pieces install now; this takes a few minutes)"
bash "$kit/scripts/setup-prefix.sh"

# --- install Ableton Live from the stick ---------------------------------------
live_installed=0
if [ "$manual_install" -eq 0 ]; then
    if [ -z "$live_exe" ] && [ -n "$live_zip" ]; then
        say "-- unpacking $(basename "$live_zip")"
        unpack_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine-setup/live-installer"
        rm -rf "$unpack_dir"; mkdir -p "$unpack_dir"
        if command -v unzip >/dev/null;   then unzip -q "$live_zip" -d "$unpack_dir"
        elif command -v bsdtar >/dev/null; then bsdtar -xf "$live_zip" -C "$unpack_dir"
        elif command -v python3 >/dev/null; then python3 -m zipfile -e "$live_zip" "$unpack_dir"
        else say "!! no program available to unpack the zip (looked for unzip, bsdtar, python3); manual steps will be printed at the end"; manual_install=1
        fi
        if [ "$manual_install" -eq 0 ]; then
            live_exe="$(find "$unpack_dir" -iname '*.exe' | head -1)"
            [ -n "$live_exe" ] || { say "!! that zip holds no installer (.exe); is it the right download from ableton.com?"; manual_install=1; }
        fi
    fi
    if [ -n "$live_exe" ]; then
        # Live 12 ships Inno Setup, Live 11 a WiX Burn bundle. Burn ignores /MERGETASKS and
        # /SUPPRESSMSGBOXES, and reads /SILENT as /quiet - no window at all - so the Inno set
        # on Live 11 installs the USB audio driver anyway and loses the wizard. /MERGETASKS
        # drops that task: a Windows USB kernel driver Wine cannot load (audio is PipeASIO).
        # Burn first - `.wixburn` is a PE section ~630 bytes in, so 4k settles it however big
        # the installer is; the Inno marker is ~680 KB in. Process substitution, not a pipe:
        # grep -q exits early, head takes SIGPIPE, and pipefail would report 141.
        live_flags=()
        if ! grep -qaF '.wixburn' <(head -c 4k -- "$live_exe") \
             && grep -qa 'Inno Setup' <(head -c 4M -- "$live_exe"); then
            live_flags=(/SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver')
            say "-- installing Ableton Live; a progress window opens, no clicks needed"
            say "   (Live is large, so this can take several minutes)"
        else
            say "-- starting the Ableton installer; from here just click through its window"
        fi
        # run from the installer's own directory so its relative payload lookups resolve
        if ( cd "$(dirname -- "$live_exe")" && \
                 WINEPREFIX="$HOME/.wine-ableton" \
                 "$HOME/.local/opt/$RUNTIME_NAME/bin/wine" \
                 "./$(basename -- "$live_exe")" "${live_flags[@]}" ); then
            live_installed=1
        else
            say "!! the Ableton installer exited with an error; instructions below"
            manual_install=1
        fi
        WINEPREFIX="$HOME/.wine-ableton" \
            "$HOME/.local/opt/$RUNTIME_NAME/bin/wineserver" -w 2>/dev/null || true
        rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/ableton-wine-setup" 2>/dev/null || true
    fi
fi

say ""
say "================================================================"
if [ "$live_installed" -eq 1 ]; then
    say "Done: Ableton Live is installed."
else
    say "Done, except Ableton Live itself. To install it manually:"
    say "  1) unpack your Ableton zip (any edition):"
    say "       unzip /path/to/ableton_live*.zip -d ~/live-installer"
    say "       (no unzip? try: bsdtar -xf FILE.zip -C ~/live-installer)"
    say "  2) run the installer through this Wine, from inside that directory:"
    say "       cd ~/live-installer && WINEPREFIX=~/.wine-ableton \\"
    say "           ~/.local/opt/$RUNTIME_NAME/bin/wine ./*.exe \\"
    say "           /SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver'"
    say "     (Live 12: the flags let it install by itself and skip a Windows-only driver;"
    say "      Live 11: drop them and click through its installer window instead)"
fi
say "Launch Live:   ~/.local/bin/ableton-live"
say "Then, inside Live:"
say "  * Settings/Preferences -> Audio -> Driver Type: ASIO -> Audio Device: PipeASIO"
say "================================================================"
exit 0
__PAYLOAD_BELOW__
