# Online authorization and `.auz` file handling

Status: implemented in the installer and launcher. The host-side routing has
been verified. Completing an account authorization remains a manual test
because it requires a real Ableton account and consumes an authorization.

Online authorization leaves Live, opens the host browser, and returns to the
same Wine prefix:

1. Live opens an Ableton HTTPS URL. Wine passes it through `winebrowser` and
   `xdg-open` to the host browser.
2. After login, Ableton returns an `ableton:` URL. The page can also provide a
   downloadable `.auz` response file.
3. The desktop MIME system runs `~/.local/bin/ableton-live` for either
   response.
4. The launcher forwards the response through the packaged Wine runtime and
   `~/works/plugs/studio`. The prefix registry then dispatches it to Live.

Authorization is bound to the prefix's `MachineGuid`. A response sent to
another prefix cannot authorize this installation.

## Historical failure

On 2026-07-20, a Live 12.4.5b7 beta in a scratch prefix replaced the installed
handler with:

    Exec=env "WINEPREFIX=/path/to/scratch-prefix" wine start %u

Four gaps broke the return path:

1. The handler filename is contested. winemenubuilder names URL handlers
   `wine-protocol-<scheme>.desktop`. A scratch prefix could export its own
   `wine-protocol-ableton.desktop` and overwrite this project's file. Its
   `Exec` line used stock Wine and the scratch prefix.
2. The installer preserved the overwritten file.
3. The installer did not pin a default handler in `mimeapps.list`, so a
   second claimant made selection ambiguous.
4. The host had no MIME registration for `.auz`. Plain
   `wine start <unix-path>` also fails because `start.exe` translates a Unix
   path only with `/unix`.

## Fix

- `scripts/install.sh` replaces a handler entry that does not route through
  `~/.local/bin/ableton-live` instead of preserving it, and stages canonical
  copies of both handler entries in `~/works/apps/ableton-live/`.
- It registers the user MIME type `application/x-wine-extension-auz` with
  the `*.auz` glob and installs
  [desktop/wine-extension-auz.desktop.in](../desktop/wine-extension-auz.desktop.in)
  for it.
- It pins both handlers with `xdg-mime default`.
- The launcher restores a missing entry or one with winemenubuilder's
  `Exec=env ... WINEPREFIX=... wine start` signature. It then rebuilds the
  desktop cache and pins the defaults again. Other hand-edited entries are
  left unchanged.
- The launcher forwards a single existing file argument through
  `wine start /unix`, so `.auz` files reach the prefix as DOS paths. Live
  documents use the direct Live executable path.
- `scripts/uninstall.sh` removes the entries, MIME package, and pinned
  default lines.

## Verification

On 2026-07-20, the repair function replaced the captured winemenubuilder
entry, created the missing `.auz` entry, pinned both defaults, preserved a
hand-edited control entry, and made no changes on its second run.

The prefix already contained the `HKCR\ableton` URL protocol and `.auz`
ProgID. No prefix change was needed. The installed handlers can be checked
with:

```bash
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
xdg-mime query default x-scheme-handler/ableton
xdg-mime query default application/x-wine-extension-auz
grep '^Exec=' "$apps/wine-protocol-ableton.desktop"
grep '^Exec=' "$apps/wine-extension-auz.desktop"
```

The expected defaults are `wine-protocol-ableton.desktop` and
`wine-extension-auz.desktop`. Both `Exec` lines should use
`$HOME/.local/bin/ableton-live`.

For the manual end-to-end check, start Live, choose online authorization,
complete the browser login, and confirm that Live reports the license.
