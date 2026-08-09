# shellcheck shell=bash
# Where the runtime and the prefix are, which tarball to act on, and what is
# running from either.
#
# Sourced, never executed. This exists because each answer was written several
# times over — the tarball selector in install.sh, make-installer.sh and
# build-audit.sh, with the same defect in all three; the prefix default in
# install.sh twice and in the launcher again; and PR #120's process scan inline
# in install.sh, where nothing else could reach it. Copies of a path do not stay
# in agreement, and the failure when they diverge is not cosmetic: #120's scan
# and the directory install.sh is about to replace have to name the same tree,
# or a runtime is swapped out from under running processes.
#
# The resolvers are pure: they echo and touch nothing, so a caller takes only
# what it wants and they can be tested without a sandbox. Binding the current
# shell to the runtime is opt-in, because only the launchers want it.
#
#   . "$here/runtime-env.sh"
#   WINE_ROOT="$(ableton_wine_root)"           # just the path
#   ableton_bind_runtime                       # the full launcher binding

# Names this library answered to before the runtime was its own thing. They are
# honoured for one release and say so once, because the rename lands in the same
# breath as a migration that moves every path a person or a script had learned -
# breaking both at once turns one afternoon of adjustment into two.
#
# Only infrastructure is listed. ABLETON_DPI_MODE, ABLETON_LIVE_VERSION and the
# rest configure Ableton Live and keep their names for good: the split is the
# point, and a second application should be able to read the difference.
works_env_compat() {
    local _pair _old _new
    for _pair in \
        ABLETON_WINE_ROOT:ABLETON_WINE_ROOT \
        ABLETON_WINEPREFIX:ABLETON_WINEPREFIX \
        ABLETON_OPT_DIR:ABLETON_OPT_DIR \
        ABLETON_RUNTIME_KEEP:ABLETON_RUNTIME_KEEP \
        ABLETON_RUNTIME_TARBALL:ABLETON_RUNTIME_TARBALL \
        ABLETON_CHANNEL:ABLETON_CHANNEL \
        ABLETON_CHANNEL_FILE:ABLETON_CHANNEL_FILE \
        ABLETON_MANIFEST_URL:ABLETON_MANIFEST_URL
    do
        _old="${_pair%%:*}"; _new="${_pair##*:}"
        # The new name always wins: someone setting both has migrated and left
        # the old one in a shell profile.
        [ -n "${!_old:-}" ] && [ -z "${!_new:-}" ] || continue
        export "$_new=${!_old}"
        echo "   note: $_old is now $_new, and will stop being read after the next release" >&2
    done
}
works_env_compat

# The directory installs live under. A seam for the tests; nothing else sets it.
ableton_opt_dir() {
    printf '%s\n' "${ABLETON_OPT_DIR:-$HOME/.local/opt}"
}

# The runtime's build name. It carries the Wine version because the artifact
# does: a tarball identifies which build it is.
ableton_runtime_name() {
    printf '%s\n' "wine-d2d1-nspa-11.13"
}

# The pre-container install path. Carries the Wine version, which is exactly why
# it is being retired: a base bump moved every user's directory.
works_legacy_root() {
    printf '%s\n' "$HOME/.local/opt/$(ableton_runtime_name)"
}

# Where the runtime is. One place, because seven scripts answered this
# separately and copies of a path do not stay in agreement.
ableton_wine_root() {
    printf '%s
' "${ABLETON_WINE_ROOT:-$(ableton_opt_dir)/$(ableton_runtime_name)}"
}

# The Ableton prefix. Separate from the runtime on purpose: a channel switch
# would change both, but a test or a clone changes only this one.
ableton_wine_prefix() {
    printf '%s\n' "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
}

# Bind this shell to the runtime: drop inherited Wine settings that would reach
# the wrong build, then export what wine and its helpers read.
#
# The unset list is deliberately the four the launchers have always cleared.
# setup-prefix.sh additionally clears WINEESYNC and WINEFSYNC and keeps doing so
# at its own call site: folding them in here would silently start dropping a
# user's WINEESYNC on every launch, which is a behaviour change wearing a
# refactor's clothes.
ableton_bind_runtime() {
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH
    WINE_ROOT="$(ableton_wine_root)"
    WINEPREFIX="$(ableton_wine_prefix)"
    WINESERVER="$WINE_ROOT/bin/wineserver"
    PATH="$WINE_ROOT/bin:$PATH"
    export WINEPREFIX WINESERVER PATH
}

# Is this a runtime tarball an install will select? The name is the whole test.
#
# The glob cannot be the selector. The build also emits
# <name>-<version>-debug.tar.zst, and `sort -V` orders that suffix *after* the
# runtime, so a glob piped to `tail -1` picks the debug tree — which carries
# bin/ and lib/ but no share/, passes `wine --version`, and then fails at launch
# with "could not exec the wine loader". Match the dated release form only and
# let every suffixed variant fall out.
#
# A predicate rather than the regex inlined at one call site, because there are
# two: the selector below, and make-installer.sh checking the tarball it was
# told to pack. Those disagreeing is not hypothetical — a name this rejects
# packs into a kit perfectly well, and the failure surfaces on the user's
# machine, where the kit's own install.sh finds nothing to install.
#
# A `+<label>` suffix is part of the release form, not a variant of it: the
# nightly channel publishes <name>-<version>+nightly.<sha>.tar.zst, and refusing
# that meant the one artifact a nightly actually ships could not be packed or
# installed. `-debug` stays refused — that is a different tree, not a label.
ableton_is_runtime_tarball() {
    local _b="${1##*/}" _nm _re
    _nm="$(ableton_runtime_name)"
    _re="^${_nm//./\\.}-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]+(\\+[A-Za-z0-9][A-Za-z0-9.]*)?\\.tar\\.zst\$"
    [[ "$_b" =~ $_re ]]
}

# The newest runtime tarball in <dir>, or nothing.
#
# Locals are underscore-prefixed: this is sourced into scripts with their own
# $found and $target.
#
# Labelled builds are held separately and used only when there is no plain
# release, because `sort -V` orders `2026.08.04.1+nightly.bf76bb2` *after*
# `2026.08.04.1` — so a directory holding a release and a nightly would hand
# back the nightly, which is the same way round the `-debug` defect went. A
# labelled build is opt-in, and ABLETON_RUNTIME_TARBALL is how you opt in.
ableton_pick_tarball() {
    local _dir="$1" _nm _f
    _nm="$(ableton_runtime_name)"
    local -a _found=() _labelled=()
    for _f in "$_dir"/"$_nm"-*.tar.zst; do
        [ -e "$_f" ] || continue          # no match: the glob came back literal
        ableton_is_runtime_tarball "$_f" || continue
        case "${_f##*/}" in
            *+*) _labelled+=("$_f") ;;
            *)   _found+=("$_f") ;;
        esac
    done
    [ "${#_found[@]}" -gt 0 ] || _found=("${_labelled[@]}")
    [ "${#_found[@]}" -gt 0 ] || return 0
    printf '%s\n' "${_found[@]}" | sort -V | tail -1
}

# --- what is running from the runtime ----------------------------------------

# The process table to read. Only the tests set this, pointing it at a fixture
# tree of fake exe symlinks; /proc cannot be stubbed through PATH the way pgrep
# can, so without a seam the accurate implementation is the untestable one.
ableton_proc_root() {
    printf '%s\n' "${ABLETON_PROC_ROOT:-/proc}"
}

# Every pid whose binary lives under the runtime. From PR #120, which found the
# reason a command line cannot answer this: Wine's in-prefix helpers show a
# Windows path in argv (C:\windows\system32\...), so no pattern reaches them,
# and a pattern also catches unrelated processes that merely mention the path.
# The exe link is the real binary — bin/wineserver, or the wine-preloader every
# in-prefix process runs from — so the match is exact and scoped to this
# runtime rather than any Wine on the machine.
ableton_runtime_pids() {
    local proc root d
    root="$(ableton_wine_root)"
    proc="$(ableton_proc_root)"
    for d in "$proc"/[0-9]*; do
        case "$(readlink "$d/exe" 2>/dev/null)" in
            "$root"/*) printf '%s\n' "${d##*/}" ;;
        esac
    done
}

# Anything at all using the runtime: the predicate to ask before replacing its
# files. The name match stays as a second opinion because failing open here
# means installing over a running runtime.
ableton_runtime_busy() {
    [ -n "$(ableton_runtime_pids)" ] || \
        pgrep -f '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1
}

# Live itself, as opposed to the support processes around it. The install
# prompt is about unsaved work, and only Live has any.
ableton_live_pids() {
    local proc p cmd
    proc="$(ableton_proc_root)"
    for p in $(ableton_runtime_pids); do
        # A process can exit between the scan above and this read — during an
        # install that is common, because the stop is what made them exit. The
        # shell reports a failed redirection itself, before tr ever runs, so
        # tr's own 2>/dev/null cannot suppress it. Check first instead.
        [ -r "$proc/$p/cmdline" ] || continue
        cmd="$(tr -s '\0' ' ' < "$proc/$p/cmdline" 2>/dev/null)" || continue
        case "$cmd" in
            *"Ableton Live"*.exe*) printf '%s\n' "$p" ;;
        esac
    done
}

ableton_live_running() {
    [ -n "$(ableton_live_pids)" ]
}

# --- identifying an installed runtime ----------------------------------------

# --- layout migration --------------------------------------------------------
# One-time move from the flat layout to the store: one directory per build,
# named from its own BUILD-INFO, with a channel symlink at the live one. Only
# install.sh calls this. It lives here because it has to agree with the
# resolvers above about where a runtime is, and those drifting apart is the
# failure this whole file exists to prevent.

# --- retention ---------------------------------------------------------------

# --- removal -----------------------------------------------------------------

# --- the manifest ------------------------------------------------------------
# A channel publishes one small document saying what it currently points at.
# Everything before this re-derived that by parsing artifact filenames, which is
# the single decision behind the selector defect, the packing defect, the
# retention tie and the update prompt having nothing to compare.
#
# Same `key: value` shape as BUILD-INFO, so ableton_buildinfo_field reads it and
# nothing needs jq:
#
#   channel:       stable
#   dist-version:  2026.08.04.1
#   installer:     install-ableton-latest.run
#   sha256:        …
#   source-commit: …
#   built-at:      2026-08-04T13:49:38Z
#   wine:          wine-11.13

