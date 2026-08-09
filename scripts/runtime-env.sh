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

# Which channel this machine follows. One word, validated against an allowlist
# rather than trusted: it selects a symlink name and, for the updater, part of a
# URL - and configuration the build does not control must not shape a request.
# That is the same constraint that ended the source-repo experiment.
# Where the followed channel is recorded. One function, because a reader and a
# writer that spell this differently disagree silently until an update goes to
# the wrong channel.
works_channel_file() {
    printf '%s\n' "${ABLETON_CHANNEL_FILE:-$(ableton_container_root)/.channel}"
}

# The directory holding every installed runtime, one per build.
ableton_container_root() {
    printf '%s\n' "$(ableton_opt_dir)/ableton-wine"
}

# The pre-container install path. Carries the Wine version, which is exactly why
# it is being retired: a base bump moved every user's directory.
works_legacy_root() {
    printf '%s\n' "$HOME/.local/opt/$(ableton_runtime_name)"
}

# The installed runtime. ABLETON_WINE_ROOT overrides it — the tests, the
# regression VMs and anyone bisecting a build rely on that, so it stays the
# outermost say.
#
# Returns what the channel points at, never the channel path itself. Two things
# turn on that, and both were measured rather than argued:
#
# /proc/PID/exe reports a path with symlinks already resolved, so a process
# launched through <container>/stable/bin/wine appears under the build's own
# name. Compare against the channel and ableton_runtime_pids matches nothing:
# the confirmation before force-closing Live never fires, the targeted kills
# reach nothing, and only the pgrep fallback PR #120 added the scan to replace
# still works — while install.sh goes on to rename the directory.
#
# And a caller that resolved once keeps the build it resolved. A channel switch
# part-way through a session cannot move the runtime under a process already
# executing from it.
ableton_wine_root() {
    local _chan _target
    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        printf '%s\n' "$ABLETON_WINE_ROOT"
        return
    fi
    _chan="$(ableton_container_root)/stable"
    if [ -e "$_chan" ]; then
        _target="$(readlink -f "$_chan" 2>/dev/null || true)"
        if [ -n "$_target" ]; then
            printf '%s\n' "$_target"
            return
        fi
    fi
    # No container yet: an install that predates the migration still has to
    # resolve and launch.
    works_legacy_root
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

# One field out of a tree's ABLETON-WINE-BUILD-INFO.txt. The file pads its
# values to a column, so the separator is a colon followed by any amount of
# space, not ": ".
ableton_buildinfo_field() {
    local _file="$1" _key="$2" _v
    [ -r "$_file" ] || return 0
    _v="$(sed -n "s/^${_key}:[[:space:]]*//p" "$_file" | head -1)"
    printf '%s\n' "${_v%"${_v##*[![:space:]]}"}"   # strip any trailing space
}

# The identity of an installed runtime: <dist-version>+<discriminator>.
# Echoes nothing when the tree cannot be named; a caller must treat that as a
# refusal, never as a default.
#
# The discriminator is source-commit where the file has one and the first seven
# characters of patch-stack where it does not. That fallback is not defensive:
# measured 2026-08-04, none of the eleven runtimes on the development machine
# carries source-commit, because the commit that writes it is not released. So
# requiring it would refuse every runtime installed anywhere today.
#
# dist-version alone cannot serve. On that machine 2026.07.29.1 appears four
# times under two different patch stacks, and 2026.07.23.1 covers both the 11.11
# and the 11.14 tree — keyed on version they would collide.
ableton_runtime_id() {
    local _dir="$1" _info _ver _disc _kind
    _info="$_dir/ABLETON-WINE-BUILD-INFO.txt"
    [ -r "$_info" ] || return 0

    _ver="$(ableton_buildinfo_field "$_info" dist-version)"
    [ -n "$_ver" ] || return 0

    _disc="$(ableton_buildinfo_field "$_info" source-commit)"
    [ -n "$_disc" ] || _disc="$(ableton_buildinfo_field "$_info" patch-stack)"
    [ -n "$_disc" ] || return 0
    # A nightly says so here rather than in dist-version. That field is the date
    # the build happened, for every build, which is the one question a directory
    # name has to answer -- putting the kind there too would mean either a second
    # date or a second separator, and the id is <version>+<discriminator> with
    # exactly one. So: 2026.08.06.1+nightly.badafaf.
    _kind="$(ableton_buildinfo_field "$_info" build-kind)"
    ableton_compose_id "$_ver" "$_disc" "$_kind"
}

# version, discriminator, kind -> the id, or nothing.
#
# Split out because two things compose one: a store entry, from a tree's own
# BUILD-INFO, and the updater's report of what a channel is offering, from a
# manifest. Those disagreeing would mean the updater naming a directory other
# than the one the install produces.
ableton_compose_id() {
    local _ver="$1" _disc="${2:0:7}" _kind="${3:-}"
    [ -n "$_ver" ] && [ -n "$_disc" ] || return 0
    [ -z "$_kind" ] || _disc="$_kind.$_disc"
    # The id becomes a directory name, so it is validated rather than trusted: a
    # BUILD-INFO is plain text inside a tarball, and a manifest arrives over the
    # network. Nothing upstream of here constrains what either holds.
    case "$_ver$_disc" in
        *[!0-9A-Za-z._-]*|*..*) return 0 ;;
    esac
    printf '%s+%s\n' "$_ver" "$_disc"
}

# --- layout migration --------------------------------------------------------
# One-time move from the flat layout to the store: one directory per build,
# named from its own BUILD-INFO, with a channel symlink at the live one. Only
# install.sh calls this. It lives here because it has to agree with the
# resolvers above about where a runtime is, and those drifting apart is the
# failure this whole file exists to prevent.

# Is <a> a newer build than <b>? built-at where both carry it, dist-version
# otherwise. Runtimes built before built-at existed have only the version, which
# ties across every nightly between two releases — that is why the field was
# added, and why this answers "no" rather than guessing when it cannot tell.
ableton_build_is_newer() {
    local _a="$1" _b="$2" _av _bv
    _av="$(ableton_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    _bv="$(ableton_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    if [ -z "$_av" ] || [ -z "$_bv" ]; then
        _av="$(ableton_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
        _bv="$(ableton_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
    fi
    [ -n "$_av" ] && [ -n "$_bv" ] || return 1
    [ "$_av" != "$_bv" ] || return 1
    [ "$(printf '%s\n%s\n' "$_av" "$_bv" | sort -V | tail -1)" = "$_av" ]
}

# Move <dir> into the store under its own id. A tree that cannot be named, or
# whose name is already taken, is set aside under <container>/<kind>-<stamp>/
# rather than deleted — these are multi-gigabyte runtimes and nothing here
# removes one behind the user's back.
ableton_store_absorb() {
    local _dir="$1" _stamp="$2" _container _id _aside
    _container="$(ableton_container_root)"
    _id="$(ableton_runtime_id "$_dir")"
    if [ -n "$_id" ] && [ ! -e "$_container/$_id" ]; then
        mv "$_dir" "$_container/$_id"
        printf '%s\n' "$_id"
        return 0
    fi
    # unnameable, or a name already held by an identical build
    _aside="$_container/$([ -n "$_id" ] && echo superseded || echo failed)-$_stamp"
    mkdir -p "$_aside"
    mv "$_dir" "$_aside/${_dir##*/}"
    return 0
}

# Migrate, or explain why not. Idempotent, and refuses rather than guessing when
# the live tree cannot be identified — installing over an unidentifiable runtime
# is the ambiguous case the store exists to prevent.
#
# Nothing is left at the legacy path. An earlier design kept a compatibility
# symlink there and it did not survive examination: the case it was chiefly
# justified by, an older .run, does not read that path, it overwrites it.
#
# The caller must already have established that nothing is running from the
# runtime: this renames the directory a running Wine executes from.
# Move a flat prefix into the Plug store. Separate from the runtime migration
# because it is a different object with different failure modes: a runtime can
# be re-downloaded and a prefix cannot, so every branch here that is not certain
# refuses rather than guesses.
#
# The move is a plain rename and needs no repair. Wine resolves everything
# relative to $WINEPREFIX, which is supplied per launch; a used prefix carries
# no absolute host path in its registry (checked against a real Live 12 install,
# plain and hex-encoded), dosdevices/c: is relative, and the absolute symlinks
# under drive_c/users point outward at the real home, which is not moving.
# Is anything running out of this Plug? The runtime scan cannot answer it: a
# process can hold a prefix while running from another Wine entirely, and
# renaming a prefix out from under a live wineserver corrupts its registry.
# Wine puts WINEPREFIX in the environment of everything it starts, so the
# environment is where the answer is.
works_plug_busy() {
    local _plug _p
    _plug="${1:-$(ableton_wine_prefix)}"
    _plug="${_plug%/}"
    for _p in "$(ableton_proc_root)"/[0-9]*; do
        # Unlike cmdline, environ is mode 400 *and* gated by ptrace_may_access,
        # so `[ -r ]` passes on our own processes where the read still fails -
        # systemd --user is one. The shell reports a failed redirection itself,
        # before tr runs, so tr's own 2>/dev/null cannot suppress it and the
        # group is what silences it. Same trap as ableton_live_pids, one file
        # further along.
        { tr '\0' '\n' < "$_p/environ" | grep -qxF "WINEPREFIX=$_plug"; } 2>/dev/null \
            && return 0
    done
    return 1
}

# Every pid Works is running, from either direction. The two scans genuinely
# differ: the runtime scan resolves /proc/PID/exe, so it cannot see a process
# whose runtime directory has since been removed, and the Plug scan reads
# WINEPREFIX out of the environment, so it finds exactly those orphans. Wine
# leaves services.exe, rpcss.exe and friends behind under names no `pkill
# wineserver` will ever match, and they hold the prefix until something asks.
works_all_pids() {
    local _p _d
    ableton_runtime_pids 2>/dev/null || true
    for _d in "$(ableton_opt_dir)"/plugs/*/ "$HOME/.wine-ableton"; do
        [ -d "$_d" ] || continue
        works_plug_holders "${_d%/}" 2>/dev/null | awk '{print $1}'
    done
}

# What is holding it, for a refusal that can be acted on rather than puzzled at.
works_plug_holders() {
    local _plug _p _cmd
    _plug="${1:-$(ableton_wine_prefix)}"
    _plug="${_plug%/}"
    for _p in "$(ableton_proc_root)"/[0-9]*; do
        { tr '\0' '\n' < "$_p/environ" | grep -qxF "WINEPREFIX=$_plug"; } 2>/dev/null || continue
        _cmd="$( { tr -s '\0' ' ' < "$_p/cmdline"; } 2>/dev/null )" || continue
        printf '%s  %s\n' "${_p##*/}" "${_cmd:0:70}"
    done
}

works_migrate_plug() {
    local legacy dest
    legacy="$HOME/.wine-ableton"
    dest="$(ableton_wine_prefix)"

    if [ -n "${ABLETON_WINEPREFIX:-}" ]; then
        echo "   plug: ABLETON_WINEPREFIX is set; leaving the prefix where it is"
        return 0
    fi
    [ "$legacy" != "$dest" ] || return 0

    # A symlink at the legacy path is someone else's arrangement, not ours.
    if [ -L "$legacy" ]; then
        echo "!! $legacy is a symlink, not a prefix; remove it and rerun" >&2
        return 1
    fi
    [ -d "$legacy" ] || return 0        # nothing to move

    # Before anything moves. install.sh stops what runs from the runtime, which
    # is not the same set: this catches a Live started from another build, or a
    # bare wine pointed at the prefix.
    if works_plug_busy "$legacy"; then
        echo "!! something is still running from $legacy, so moving it now would" \
             "corrupt its registry. Close it, or run \`works stop\`, then rerun:" >&2
        works_plug_holders "$legacy" | sed 's/^/     /' >&2
        return 1
    fi

    # Both present is the one genuinely ambiguous state: two prefixes, each
    # possibly holding a different Live and different authorisation. Guessing
    # loses work, so name both and stop.
    if [ -e "$dest" ]; then
        echo "!! a prefix already exists at $dest and another at $legacy;" \
             "keep the one you want and remove the other, then rerun" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")"

    # Within one filesystem this is a rename: atomic, instant, and no free space
    # required whatever the prefix weighs. Across filesystems mv copies and then
    # deletes, so a 16G prefix needs 16G free and minutes of I/O - and a failure
    # halfway leaves a partial copy that would read as "a prefix at both paths"
    # on the next run. Check first, and clean up after ourselves if it fails.
    if [ "$(stat -c %d "$legacy" 2>/dev/null)" != "$(stat -c %d "$(dirname "$dest")" 2>/dev/null)" ]; then
        local _need _free
        _need="$(du -sk "$legacy" 2>/dev/null | cut -f1)"
        _free="$(df -Pk "$(dirname "$dest")" 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -n "$_need" ] && [ -n "$_free" ] && [ "$_free" -le "$_need" ]; then
            echo "!! $dest is on another filesystem and moving the prefix there needs" \
                 "$((_need / 1024)) MB, with $((_free / 1024)) MB free" >&2
            return 1
        fi
        echo "   plug: $dest is on another filesystem, so this is a copy, not a rename"
    fi

    if ! mv "$legacy" "$dest"; then
        # Only ever the destination: the source is what we failed to move.
        [ -e "$dest" ] && [ -e "$legacy" ] && rm -rf "$dest"
        echo "!! moving the prefix to $dest failed; it is still at $legacy" >&2
        return 1
    fi
    echo "   plug: moved the prefix to $dest"
}

ableton_migrate_layout() {
    local legacy container chan stamp id other d absorbed
    legacy="$(works_legacy_root)"
    container="$(ableton_container_root)"
    chan="$container/stable"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        echo "   layout: ABLETON_WINE_ROOT is set; leaving the install where it is"
        return 0
    fi

    # Already migrated. A real tree at the legacy path beside it is not
    # corruption: an older .run knows nothing about the store and writes one
    # there. That is a normal action on a machine holding an older installer, so
    # recover rather than refuse — identify both and keep the newer live.
    if [ -L "$chan" ]; then
        if [ -d "$legacy" ] && [ ! -L "$legacy" ]; then
            other="$(readlink -f "$chan" 2>/dev/null || true)"
            if [ -z "$(ableton_runtime_id "$legacy")" ] && \
               { [ -z "$other" ] || [ -z "$(ableton_runtime_id "$other")" ]; }; then
                echo "!! neither $legacy nor $chan can be identified from its" \
                     "BUILD-INFO; remove whichever is stale and rerun" >&2
                return 1
            fi
            id="$(ableton_store_absorb "$legacy" "$stamp")"
            if [ -n "$id" ] && [ -n "$other" ] && ableton_build_is_newer "$container/$id" "$other"; then
                ln -sfn "$id" "$chan"
                echo "   layout: adopted the newer $id from $legacy"
            else
                echo "   layout: kept $legacy as a store entry; the channel stays where it was"
            fi
        fi
        return 0
    fi

    # Nothing installed: install.sh creates the store itself.
    if [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
        return 0
    fi

    # -L as well as -e: a dangling link from an older layout reads as absent to
    # -e alone and would fall through to a silent no-op.
    if [ -L "$legacy" ]; then
        echo "!! $legacy is a symlink, not a runtime; remove it and rerun" >&2
        return 1
    fi

    id="$(ableton_runtime_id "$legacy")"
    [ -n "$id" ] || {
        echo "!! $legacy carries no readable ABLETON-WINE-BUILD-INFO.txt, so it" \
             "cannot be named; installing over it would be a guess" >&2
        return 1; }

    mkdir -p "$container"
    # Never a bare mv. When an entry of this id is already in the store - which
    # happens whenever the channel symlink is genuinely absent rather than
    # dangling - mv lands the legacy tree *inside* it, where retention and the
    # container-scoped uninstall both stop seeing it while the channel quietly
    # points at the incumbent. ableton_store_absorb is the guard the already-
    # migrated branch above and install.sh both already use.
    absorbed="$(ableton_store_absorb "$legacy" "$stamp")"
    ln -sfn "$id" "$chan"

    # The dated rollbacks travel too, and become readable in the process: each
    # carries its own BUILD-INFO, so a timestamp that recorded when a runtime
    # was replaced becomes a name that says which build it holds. Left behind
    # they are invisible to the container-scoped uninstall and orphan several
    # gigabytes apiece.
    for d in "$legacy"-rollback-* "$legacy".failed-*; do
        [ -e "$d" ] || continue
        ableton_store_absorb "$d" "$stamp" >/dev/null
    done
    if [ -n "$absorbed" ]; then
        echo "   layout: moved the runtime to $container/$id"
    else
        echo "   layout: the store already held an entry named $id, so the tree at" \
             "$legacy was set aside under superseded-$stamp; the channel points at" \
             "the entry that was already there"
    fi
}

# --- retention ---------------------------------------------------------------

# Keep this many entries per channel. A count rather than a policy: a channel
# that turns over nightly wants a smaller one than a channel that turns over
# monthly, and an unpacked runtime is ~392M against a 40-minute rebuild.
ableton_runtime_keep() {
    local _n="${ABLETON_RUNTIME_KEEP:-10}"
    case "$_n" in ''|*[!0-9]*) _n=10 ;; esac      # nonsense reverts to the default
    [ "$_n" -ge 1 ] || _n=1                       # never prune to nothing
    printf '%s\n' "$_n"
}

# Drop the oldest entries past the limit. Called after a successful install,
# never before, so a failure cannot leave a user with neither the new runtime
# nor the old one.
#
# Ordering is by built-at, not by the version in the name. Names tie: every
# nightly between two releases carries the same dist-version, so sorting on the
# name falls through to comparing hashes - deterministic, and unrelated to age.
# Entries predating built-at sort oldest as a group, which they are.
#
# What the channel points at is never removed, whatever the count says. A
# channel pointing at a pruned entry is a broken install produced by
# housekeeping.
ableton_prune_runtimes() {
    local _container _keep _live _e _id _at _ver _key
    _container="$(ableton_container_root)"
    [ -d "$_container" ] || return 0
    _keep="$(ableton_runtime_keep)"
    # Every channel's target, not just this machine's. A second channel pointing
    # at an entry pruned on behalf of the first is a broken install produced by
    # housekeeping - the rule has to hold for all of them.
    local -a _pinned=()
    for _e in "$_container"/*; do
        [ -L "$_e" ] || continue
        _live="$(readlink -f "$_e" 2>/dev/null || true)"
        [ -n "$_live" ] && _pinned+=("$_live")
    done

    local -a _victims=()
    while IFS=$'\t' read -r _key _e; do
        [ -n "$_e" ] || continue
        _victims+=("$_e")
    done < <(
        for _e in "$_container"/*; do
            [ -d "$_e" ] && [ ! -L "$_e" ] || continue
            _id="$(ableton_runtime_id "$_e")"
            [ -n "$_id" ] || continue        # quarantine directories are not entries
            _at="$(ableton_buildinfo_field "$_e/ABLETON-WINE-BUILD-INFO.txt" built-at)"
            _ver="$(ableton_buildinfo_field "$_e/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
            if [ -n "$_at" ]; then printf '1 %s\t%s\n' "$_at" "$_e"
            else                   printf '0 %s\t%s\n' "$_ver" "$_e"; fi
        done | sort -V | head -n -"$_keep"
    )

    local _p _keepit
    for _e in ${_victims+"${_victims[@]}"}; do
        _keepit=""
        for _p in ${_pinned+"${_pinned[@]}"}; do
            [ "$_e" = "$_p" ] && { _keepit=1; break; }
        done
        [ -z "$_keepit" ] || continue
        rm -rf "$_e" && echo "   pruned $(basename "$_e")"
    done
}

# --- removal -----------------------------------------------------------------

# Remove every runtime this installer owns. Lives here rather than in
# uninstall.sh because it has to agree with the resolvers above about where
# runtimes are, and because deleting trees is worth testing - which needs a
# function with a seam, not inline code in a script that also stops systemd
# units and rewrites the desktop database.
ableton_remove_runtimes() {
    local _container _legacy _d
    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        # The user pinned a path; remove that and nothing else - but check what
        # it names first. This runs `rm -rf` on a variable, and a stale exported
        # value left from a test session would otherwise remove whatever it
        # happens to point at.
        case "$ABLETON_WINE_ROOT" in
            ""|/|"$HOME"|"$HOME"/)
                echo "!! ABLETON_WINE_ROOT is '$ABLETON_WINE_ROOT'; refusing to remove that" >&2
                return 1 ;;
        esac
        [ -d "$ABLETON_WINE_ROOT/bin" ] || {
            echo "!! $ABLETON_WINE_ROOT has no bin/ and does not look like a runtime;" \
                 "refusing to remove it" >&2
            return 1; }
        rm -rf "$ABLETON_WINE_ROOT" && echo "removed $ABLETON_WINE_ROOT"
        return 0
    fi

    # One directory holds every entry, every channel and every set-aside tree, so
    # this is a single removal rather than a sibling glob. That glob is what
    # would orphan multi-gigabyte directories the moment any suffix joined the
    # runtime name - and the store's names are nothing but suffixes.
    _container="$(ableton_container_root)"
    [ ! -e "$_container" ] || { rm -rf "$_container" && echo "removed $_container"; }

    # An install that never migrated still has the flat layout. -L as well as
    # -e so a dangling link from an older layout is cleared rather than left;
    # rm -rf on a symlink removes the link, never its target.
    _legacy="$(works_legacy_root)"
    if [ -e "$_legacy" ] || [ -L "$_legacy" ]; then
        rm -rf "$_legacy" && echo "removed $_legacy"
    fi
    for _d in "$_legacy"-rollback-* "$_legacy".failed-*; do
        [ -e "$_d" ] || continue    # unmatched glob stays literal; skip, don't abort
        rm -rf "$_d" && echo "removed $_d"
    done
}

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

