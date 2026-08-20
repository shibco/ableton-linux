# shellcheck shell=bash
# Sourceable runtime indirection. ableton_runtime_link <runtime-root> prints a
# stable, user-owned path that resolves to that runtime, creating or re-pointing
# it as needed, and returns 1 when it cannot provide one.
#
# User configuration must never record the runtime root itself. On Nix that root
# is a /nix/store path: it is content-addressed, so every upgrade produces a new
# one, and `nix run` leaves no GC root, so nix-collect-garbage may delete it. A
# .desktop file or a systemd unit that copied such a path in then launches an
# old package, or nothing at all. Naming this link instead survives both, and
# every launcher re-points it, so an upgrade needs no re-run of any setup step.
#
# On a store runtime the link doubles as an indirect garbage-collector root -
# the same mechanism `nix build`'s result symlink uses. It goes through the nix
# daemon, so it needs no privileges, and it keeps an otherwise unrooted `nix
# run` closure alive for as long as the link exists; deleting the link releases
# it. Nothing else deletes it: it is created at launch, so no install manifest
# records it, and the Nix package ships no uninstaller. Only the Nix package
# ships this file, so a .run install never creates the link at all.

ableton_runtime_link() {   # <runtime-root> -> stable path naming that runtime
    local root="${1:-}" link target dir current tmp
    [ -n "$root" ] && [ -d "$root" ] || return 1
    # Beside the rest of the runtime's user-side staging, under the same
    # $ABLETON_DATA_HOME every other script in this kit addresses, so an
    # XDG-relocated install keeps the link with the rest of that install.
    link="${ABLETON_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ableton-wine}/runtime"
    target="$(cd -- "$root" && pwd -P)" || return 1
    # Already current: skip the daemon round trip every launch would otherwise
    # pay. -e follows the link, so a dangling one is rebuilt (and re-rooted)
    # instead of being reported as good.
    if [ "$(readlink "$link" 2>/dev/null)" = "$target" ] && [ -e "$link" ]; then
        printf '%s\n' "$link"
        return 0
    fi
    dir="${link%/*}"
    mkdir -p "$dir" 2>/dev/null || return 1
    # Whatever holds the name now must be a link this project maintains: a
    # real file or directory there was created by something else, and stays.
    current=""
    if [ -e "$link" ] || [ -L "$link" ]; then
        [ -L "$link" ] || return 1
        current="$(readlink "$link" 2>/dev/null)" || return 1
    fi
    case "$target" in
        /nix/store/*)
            # --add-root both writes the symlink and registers it; --realise is
            # a no-op on a path already in the store (this one is: we are
            # running from it).
            #
            # It has to write the name itself - an indirect root records the
            # link's own path, so a link created elsewhere and renamed here
            # would register a root that no longer exists. That is safe: over a
            # link already pointing into the store nix replaces it through a
            # temp name and rename(2), same as below. It refuses one pointing
            # anywhere else, so clear only that case - the single window where
            # the name is briefly absent, and only when crossing into the store
            # for the first time.
            case "$current" in
                ""|/nix/store/*) ;;
                *) rm -f "$link" || return 1 ;;
            esac
            if command -v nix-store >/dev/null 2>&1 \
               && nix-store --realise "$target" --indirect --add-root "$link" \
                    >/dev/null 2>&1; then
                printf '%s\n' "$link"
                return 0
            fi
            # No daemon, or a store that refuses roots: an unrooted symlink is
            # still better in user configuration than the store path itself.
            ;;
    esac
    # Rename, never unlink-then-link: two runtimes can launch at once (a beta
    # beside a stable), and a reader resolving $link/bin/... during the gap
    # would find nothing. mv -T over the link is rename(2), so a reader sees
    # the old runtime or the new one and never a missing path. $$ keeps two
    # launchers off the same temp name.
    tmp="$link.tmp.$$"
    ln -sfn "$target" "$tmp" 2>/dev/null || return 1
    mv -Tf "$tmp" "$link" 2>/dev/null || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$link"
}
