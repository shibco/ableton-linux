# shellcheck shell=bash
# Which runtime tarball a script should act on.
#
# Sourced, never executed. This exists because the answer was written three
# times - install.sh, make-installer.sh and build-audit.sh each had a copy, and
# the same defect was in all three.

# The runtime's build name. It carries the Wine version because the artifact
# does: a tarball identifies which build it is.
ableton_runtime_name() {
    printf '%s\n' "wine-d2d1-nspa-11.13"
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
