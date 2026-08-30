# Installer pre-flight settings: frozen behaviour matrix

Refrozen on 2026-08-28 after fixture corrections, clean-context execution, and
repeated adversarial review. Production work must satisfy these assertions
without weakening them.

This file is the executable-coverage index for the confirmed pseudocode. A
behaviour is covered only when the named test asserts its externally observable
result. The tests are frozen after adversarial review; implementation changes
must satisfy them rather than weaken them.

## Action routing and sequential UI

| Behaviour ID | Pseudocode branch | Frozen assertion |
|---|---|---|
| ACT-FRESH | No valid managed ownership: offer **Install** and Quit; Install is default | `test-preflight-menu.sh`: exact action block and delegated `install` |
| ACT-HEALTHY | Valid configuration/marker and complete prefix: Update, Reinstall, Remove, Quit | `test-preflight-menu.sh`: exact custom-prefix action block and Update default |
| ACT-INCOMPLETE | Recognised managed prefix is incomplete: Reinstall, Remove, Quit; no Update | `test-preflight-menu.sh`: exact incomplete action block |
| ACT-FOREIGN | Foreign Wine files are not ownership evidence | `test-preflight-menu.sh`: unmarked `system.reg` stays fresh Install |
| ACT-EVIDENCE | Marker-only/config-only ownership is recognised; missing targets are incomplete; malformed/symlink evidence is ignored; a valid config has precedence over conflicting default-marker evidence; optional support alone is not ownership | `test-preflight-menu.sh`: complete/incomplete marker and config, fully valid symlink referents, both config/marker conflict directions, malformed-marker precedence, preferences-only and support-only matrix |
| ACT-DEFAULT-ROUTING | Enter/non-TTY selects the state default; Remove directly selects uninstall | `test-preflight-menu.sh`: healthy/incomplete TTY and non-TTY routes plus Remove |
| ROUTE-EXPLICIT | An explicit command skips action and setting prompts | `test-preflight-menu.sh`: explicit Update delegates unchanged |
| ROUTE-NONTTY | No TTY: choose state default without prompting or persisting questionnaire defaults | `test-preflight-menu.sh`: stdin `/dev/null` delegates fresh `install` and healthy `update` unchanged; saved-preference checksum is stable |
| NAV-ORDER | Ask the six questions directly, one at a time, in the confirmed order | `test-preflight-menu.sh`: live pre-answer frontier forbids future headings/delegation, then normalized adjacent heading/explanation/options/Esc blocks, strict heading order, exact counts, one delegation after question 6, no seventh prompt/summary |
| NAV-EXPLANATIONS | Each question has its confirmed one-line explanation | `test-preflight-menu.sh`: exact explanation immediately adjacent to its own heading |
| NAV-CHOICES | Each option is selected on its question; there is no settings submenu or summary menu | `test-preflight-menu.sh`: all non-default answers and absence of `Choose a setting` |
| NAV-OPTION-MATRIX | Every selectable row maps to its exact flag or retained default | `test-preflight-menu.sh`: five PTY paths cover all 19 choices |
| NAV-BACK | Escape from question N returns to N-1 and retains the draft answers | `test-preflight-menu.sh`: question 3 to 2, revised answer, retained other values |
| NAV-BACK-MATRIX | Escape returns one step at each boundary from questions 2 through 6 without an intervening menu, summary or different question | `test-preflight-menu.sh`: five-boundary PTY loop with transcript-segment rejection |
| NAV-FIRST-BACK | Escape from question 1 returns exactly to the action menu | `test-preflight-menu.sh`: action prompt appears twice |
| NAV-ACTION-RESET | Quit or a changed action discards the uncommitted setting draft | `test-preflight-menu.sh`: Quit discards; Update draft followed by Reinstall reloads 2048 and delegates no flag |
| NAV-EXPLICIT-DEFAULTS | Typing defaults resets differing saved/current values while Enter retains them | `test-preflight-menu.sh`: non-default saved fixture emits all six reset flags |
| NAV-VALIDATION | Invalid direct custom worker input reprompts on question 4 | `test-preflight-menu.sh`: 0, 64 and text fail; 63 proceeds |
| NAV-CURRENT | Valid saved settings and any valid existing custom buffer are the Enter defaults | `test-preflight-menu.sh`: saved values and 2048 shown as Current; Update has no synthetic flags |
| DEFAULTS | Fresh defaults are 128/take/auto/auto/auto/performance | `test-preflight-menu.sh`: default labels and no arguments on straight Enter path; `test-preflight-preferences.sh`: absent launcher defaults; `test-preflight-integration.sh`: coordinated 128 seed |
| CLI-ROUTING | Only values deliberately changed in the questionnaire become flags | `test-preflight-menu.sh`: exact delegated argument strings for direct and backtracked paths |
| HEADER-READONLY | The transport UI never persists a draft, default or current value, even transiently, before delegation | `test-preflight-menu.sh`: delegation-time and final full HOME snapshots including type, mode, link target, bytes, device/inode, birth time and nanosecond mtime/ctime for every PTY/non-TTY run |

## Preference and PipeASIO data boundaries

| Behaviour ID | Pseudocode branch | Frozen assertion |
|---|---|---|
| PREF-API | One side-effect-free library owns validation, merge, generation tokens, writes and removal | `test-preflight-preferences.sh`: required function API |
| PREF-DEFAULTS | Absent store returns compatibility defaults without creating a file | `test-preflight-preferences.sh`: exact values and absence after read |
| PREF-LOAD | Exact format 1 loads every saved launcher value | `test-preflight-preferences.sh`: all five non-default values |
| PREF-MERGE | One strict API overlays explicit CLI intent on saved/default values without environment | `test-preflight-preferences.sh`: absent, saved and invalid merge cases |
| PREF-ENV | Non-empty environment is a one-run override; empty means unset | `test-preflight-preferences.sh`: mixed saved/environment result |
| PREF-COMPAT | `ABLETON_POWER=on|auto` maps to performance; unknown values fail | `test-preflight-preferences.sh`: aliases and actionable invalid-value error |
| PREF-MALFORMED | Malformed current data warns, falls back for launch, and is never rewritten by a reader | `test-preflight-preferences.sh`: duplicate-key fixture, defaults, checksum |
| PREF-FUTURE | Unknown future format is rejected and preserved | `test-preflight-preferences.sh`: format 2 validation/write refusal |
| PREF-VALIDATION | Exact seven-line record has its managed header first and every key exactly once; comments, order, whitespace, CRLF, unknown/incomplete/NUL/symlink/directory variants fail closed | `test-preflight-preferences.sh`: every-key missing/duplicate plus exact-layout/header/object matrix with identity-and-time snapshots |
| PREF-APPLY-UNSAFE | Future, binary, indirect and incomplete optional stores cannot block launch | `test-preflight-preferences.sh`: defaults plus environment overlay, warning and exact object preservation for every unsafe shape |
| PREF-HOSTILE | Invalid values and shell metacharacters remain inert; all stored/environment grammars fail closed | `test-preflight-preferences.sh`: field matrices and command-substitution sentinels |
| PREF-WRITE | Exact record is atomically published as a replacement at mode 0600 | `test-preflight-preferences.sh`: exact bytes, mode, changed inode and no remaining temporary file |
| PREF-PUBLISH-FAIL | A replacement-write failure cannot truncate or alter the prior record | `test-preflight-preferences.sh`: zero-size-limit failure, exact old-object snapshot and temporary cleanup |
| PREF-RACE | Writer compares the original object-generation token and never follows a symlink | `test-preflight-preferences.sh`: stale-token, symlink and valid-to-valid replacement fixtures |
| PREF-ABA | Same-byte inode replacement and same-inode modify/restore races invalidate the generation token | `test-preflight-preferences.sh`: inode-replacement and timestamp-preserving content-ABA fixtures retain the raced object exactly |
| PREF-REMOVE | The preference removal helper removes a valid unchanged record | `test-preflight-preferences.sh`: valid removal plus changed and malformed file retention |
| BUFFER-READ | Read one unique integer from 32 through 8192, including custom values | `test-preflight-preferences.sh`: boundary/preset/custom/invalid values |
| BUFFER-WRITE | Only five offered presets may be newly requested; unrelated bytes/order survive | `test-preflight-preferences.sh`: exact before/after fixtures, preset loop and custom refusal |
| BUFFER-EOF | Updating an existing buffer preserves whether the original file did or did not end in a newline | `test-preflight-preferences.sh`: exact byte comparisons for both final-newline states |
| BUFFER-MISSING | A missing key in one unique `[pipeasio]` section is inserted inside it | `test-preflight-preferences.sh`: section-scoped insertion |
| BUFFER-AMBIGUOUS | Duplicate key/section, NUL, symlink, directory and stale token are preserved | `test-preflight-preferences.sh`: refusal/checksum loop |
| BUFFER-SECTIONS | Only the key inside one unique `[pipeasio]` section is authoritative; no section is preserved | `test-preflight-preferences.sh`: competing other-section keys, scoped insertion and absent-section immutable refusal |
| PIPEASIO-SEED-PROVENANCE | A fresh coordinated seed publishes rollback-only producer provenance before its no-clobber rename, promotes only the exact renamed producer to a full generation, and permits commit only after promotion. Rollback removes matching producer temp/final objects, preserves foreign or same-byte competing objects, and rejects unsafe paths or malformed evidence without mutation. Full commit retires only the journal. | `test-preflight-preferences.sh`: before-rename, post-rename/pre-promotion, full-promotion, no-clobber, same-byte replacement, full-commit and strict four-line schema/path matrices, including foreign directory, missing terminal LF and fifth-line evidence; `test-installer-lifecycle.sh`: extracted production-writer transient ordering, injected destination race and all four real `setup-prefix.sh` recovery entry points; `test-preflight-integration.sh`: provisional commit-boundary rollback and malformed two-domain coordinator refusal/preservation |

## Dispatcher, transaction and lifecycle integration

| Behaviour ID | Pseudocode branch | Frozen assertion |
|---|---|---|
| CLI-SCHEMA | Six exact `--flag=value` grammars; bare, empty, spaced, invalid and any duplicate forms fail for Install and Update; flags belong only to those actions | `test-preflight-integration.sh`: valid plan/commit plus invalid-form/value, identical/conflicting duplicate and unrelated-command matrices |
| CLI-COMMIT-MATRIX | Every selectable equivalence class maps exactly and without duplicate records through both Install and Update | `test-preflight-integration.sh`: 42 isolated commits with exact-line/count checks plus all 1–63 worker values through both parsers |
| DRY-RUN | `plan` and `--dry-run` describe all intent, mutate no user root and start no core transaction | `test-preflight-integration.sh`: fresh plan, option alias and existing Update snapshots |
| FRESH-SEED | Coordinated Install with absent PipeASIO uses selected/default 128 inside core, and every offered preset is consumed by the real prefix writer | `test-preflight-integration.sh`: created 128 and core seed log; `test-installer-lifecycle.sh`: extracted production writer consumes 64/128/256/512/1024 exactly with durable promoted provenance |
| NO-IMPLICIT-PREFS | Launcher environment/current display values are not silently persisted | `test-preflight-integration.sh`: environment without flags creates no preference file; menu current path delegates no flags |
| INTENT-ORIGIN | CLI intent overlays saved/default values; conflicting environment is never persisted | `test-preflight-integration.sh`: absent exact record, saved exact merge and no-flag checksum |
| EXPLICIT-COMMIT | Explicit launcher choices write one strict record only after successful core and its pre-flight commit | `test-preflight-integration.sh`: core/preflight stubs observe unchanged settings; exact record and 0600 appear only afterward |
| DPI-CORE | Selected DPI is exported for prefix validation and mutation immediately | `test-preflight-integration.sh`: validation/core call logs contain fractional DPI |
| MERGE | A partial explicit update changes one field and retains the other saved/current values | `test-preflight-integration.sh`: power-only update fixture and untouched 2048 buffer |
| EXISTING-BUFFER | Existing stable unique PipeASIO is patched after core without replacing unrelated data | `test-preflight-integration.sh`: update fixture preserves comment and changes one line |
| BUFFER-RACE | Buffer changed during core is preserved and reported without failing committed core or independent preferences | `test-preflight-integration.sh`: raced file plus independent power commit |
| PREF-COORDINATOR-RACE | Valid or absent preferences changed/created during core are retained | `test-preflight-integration.sh`: two stub-controlled core races, exact replacement and warning |
| CORE-FAIL | Runtime-component, prefix core, after-seed prefix failure, provisional seed at commit, malformed recovery evidence, either pre-flight commit failure, or a second-domain rollback-preflight failure exposes/commits neither launcher setting domain | `test-preflight-integration.sh`: stubs assert settings unchanged before/during core; existing checksums and fresh absence after forced failures; exact producer cleanup for valid provisional recovery; malformed journal/settings/active evidence preservation with both domain preflights and zero domain mutations; forced second-domain preflight failure proves every rollback preflight finishes in order before either rollback mutates the exact prefix/settings/journal/active generations |
| POSTCORE-FAIL | Preference publication or component cleanup failure preserves committed core and continues independent work | `test-preflight-integration.sh`: unsafe preference destination with buffer commit and forced component cleanup with preference commit |
| MALFORMED-PRESERVE | Explicit changes do not overwrite malformed preferences | `test-preflight-integration.sh`: checksum and warning after successful core |
| INTEGRATION-FAIL | Optional launcher/support or Link failure never rolls back core or blocks independent preferences | `test-preflight-integration.sh`: forced integration/Link failures |
| STANDALONE-SEED | Direct `prefix create` retains historical 256 default | `test-preflight-integration.sh`: absent internal seed and resulting 256 through the coordinator stub; `test-installer-lifecycle.sh`: extracted production writer with no override writes exactly 256 |

## Consumers, ownership, packaging and documentation

| Behaviour ID | Pseudocode branch | Frozen assertion |
|---|---|---|
| LAUNCHER-CONSUMERS | Live and Max apply every applicable saved preference before launch, with environment precedence | `test-launcher-transactions.sh`: fake-Wine environment, RT and Live shortcut wrappers plus exact Live Options/managed-marker results for audio workers |
| POWER-PROFILE | Saved Performance/Balanced reach `powerprofilesctl`; Don't change bypasses it; unavailable profile continues | `test-launcher-transactions.sh`: both-launcher logging wrapper matrix |
| SUPPORT-FALLBACK | Missing optional preferences support launches with legacy Performance behavior | `test-launcher-transactions.sh`: isolated launcher copies without `preferences.sh` |
| UNINSTALL-OWNERSHIP | Delete-prefix removes valid preferences after runtime and prefix removal. Keep-prefix keeps preferences. | `test-uninstall-boundary.sh`: keep-prefix behavior and delete-prefix removal order; `test-preflight-preferences.sh`: valid, changed, and malformed records |
| PACKAGE-RUN | Self-extracting kit contains/inlines the preference reader needed before extraction | `test-preflight-menu.sh`: rendered-header questionnaire reads current values; `test-preflight-integration.sh`: normal packaging is statically connected to the same dynamically exercised exact stage/audit functions, whose audit rejects corruption |
| PACKAGE-INSTALL | Installed integration includes exact non-executable `preferences.sh` bytes | `test-desktop-integration.sh`: real isolated integration install |
| PACKAGE-MANIFEST | The installed-file list includes the support library. Mutable preferences remain separate. | `test-preflight-integration.sh`: installed-file list, uninstall use, and checked removal |
| PACKAGE-VERIFY | Payload verifier requires exact source bytes at mode 0644 | `test-preflight-integration.sh`: isolated `expected_from_source` assertion |
| PACKAGE-NIX | Nix source-stages and exact-byte audits every library in both launcher locations | `test-preflight-integration.sh`: comment-stripped structural dual-loop and exact `cmp` audit assertions for both destinations |
| DOCS | Flags, values, 128 default, persistence and Escape navigation are user documented | `test-preflight-integration.sh`: README/INSTALLER searches |

Every confirmed pseudocode branch above has at least one frozen assertion. The
final adversarial review found no remaining P0/P1 coverage gap.
