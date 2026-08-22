# Reliable MIDI and audio hotplug

Status: implementation design, reviewed 2026-08-22 against current `main`
(`ee464eb`), Wine 11.16, the project's complete Wine/PipeASIO patch series,
Linux USB and ALSA sequencer behavior, and current PipeWire/WirePlumber
policy.

This supersedes the 2026-08-02 prototype design. The original dirty worktree,
prototype logs, binaries, patches, and sources remain untouched at
`../ableton-linux-worktree/moonshot-midi-hotplug`.

## Decision

There are two independent recovery authorities:

1. Wine's ALSA MIDI driver owns MIDI discovery, identity, disconnect, and
   reconnect. WinMM must expose its current dense inventory instead of a
   process-lifetime cache.
2. PipeASIO owns audio route intent and recreates its own PipeWire links. It
   keeps the ASIO-facing buffers and channel identities stable while a target
   is absent.

`udev`, WirePlumber, and an external graph monitor are useful observations,
not recovery authorities. A persistent ALSA MIDI facade is retained only as
a compatibility fallback if a real Live test proves that Live ignores a
correctly updated WinMM inventory and `DBT_DEVNODES_CHANGED`.

The smallest complete patch set is therefore:

- one Wine patch for a stable, dynamic winealsa MIDI catalog and topology
  notification;
- one Wine patch for refreshable WinMM MIDI mappings and stable open handles;
- one PipeASIO patch for persistent route intent, compatible relinking, and
  PipeWire reconnection;
- test-tool changes in the repository.

Do not add a udev daemon, a graph-link guardian, automatic Live/Wine restarts,
or a reset on every topology event.

## What exists and what does not

| Area | Existing work | Remaining defect |
|---|---|---|
| MIDI reconnect | Patch 0028 subscribes to ALSA System Announce and rematches a startup-known port after its client ID changes. | It handles only `PORT_START`, uses the first display-name match, cannot add or remove WinMM devices, and its announce consumer exists only while at least one MIDI input is open. |
| MIDI prototype | The August 2 patches grew winealsa and WinMM tables and broadcast `DBT_DEVNODES_CHANGED`; `fakectl` made a probe count grow from 3 to 4 in about 450 ms. | Fixed 32-entry reserves, name identity, no shrink, moving shared maps, cross-process notification storms, no empty/output-only session, no Live or USB test. These are evidence, not release patches. |
| Audio | PipeASIO replaced WineASIO and gained buffer, rate, quantum, fallback, clock-domain, and multi-device hardening. | Links are one-shot objects built from current numeric PipeWire globals. There is no selected-target disappearance/reappearance state machine or core-restart recovery. |
| Documentation | Main promised automatic in-use audio recovery. | The actual procedure is still “None, then PipeASIO”; this branch removes that overclaim until the release gate passes. |

The old local branch has no commits ahead of `main` and has no remote PR. Its
actual work is uncommitted in the existing worktree, dated 2026-08-02 rather
than mid-July. The relevant July lineage is patch 0028 on July 14, PipeASIO on
July 17, and the manual audio recovery note on July 18.

[GitHub issue 46](https://github.com/shibco/ableton-linux/issues/46) is the
outstanding new-after-Live-start MIDI case. [PR 118](https://github.com/shibco/ableton-linux/pull/118)
contains the P12 analysis but no implementation. [PR 121](https://github.com/shibco/ableton-linux/pull/121)
and [PR 170](https://github.com/shibco/ableton-linux/pull/170) supply PipeASIO
foundations but never put Live in the recovery loop. [PR 152](https://github.com/shibco/ableton-linux/pull/152)
overlaps MIDI device identity and `DRV_QUERYDEVICEINTERFACE`; its identity
helper should be shared or absorbed, and its first-directory-entry/stale-path
bugs must not be copied. [PR 236](https://github.com/shibco/ableton-linux/pull/236)
changes launch/options/test code but no PipeASIO driver patch, so it has little
implementation overlap.

## Why the boundary is ALSA/PipeWire, not USB

The physical path is:

```text
USB or another transport
  -> kernel driver
  -> ALSA sequencer or PipeWire registry
  -> winealsa/WinMM or PipeASIO
  -> Live
```

Linux may disconnect a USB interface at any time, abort pending I/O, then
probe a new device object on return. ALSA USB MIDI consequently republishes a
sequencer client/port; PipeWire republishes registry objects with new global
IDs. That is normal lifetime behavior.

ALSA System Announce is the authoritative MIDI topology feed because it also
covers virtual, Bluetooth, and network sequencer clients. `udev` is both too
early and USB-only. PipeWire's registry is the authoritative audio graph feed.
WirePlumber reconnect/default-target policy applies to managed application
streams, not PipeASIO's manually linked duplex filter.

References:

- [Linux USB hotplug](https://docs.kernel.org/driver-api/usb/hotplug.html)
- [Linux USB callbacks](https://docs.kernel.org/driver-api/usb/callbacks.html)
- [ALSA sequencer](https://www.alsa-project.org/alsa-doc/alsa-lib/seq.html)
- [ALSA sequencer events](https://www.alsa-project.org/alsa-doc/alsa-lib/group___seq_events.html)
- [PipeWire registry](https://docs.pipewire.org/group__pw__registry.html)
- [WirePlumber linking policy](https://pipewire.pages.freedesktop.org/wireplumber/policies/linking.html)
- [WirePlumber policy settings](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/settings.html)

## Enforceable recovery contract

From the first usable endpoint published by ALSA or PipeWire:

- the runtime notices a stable new topology within two seconds;
- a returning selected/open device is usable within five seconds without
  restarting Live or wineserver;
- a new MIDI endpoint appears in current WinMM enumeration, opens, and moves
  data;
- a new audio interface appears in PipeASIO settings and becomes usable after
  selection without reloading the driver;
- a compatible selected audio interface relinks without an ASIO reset;
- there are no duplicate endpoints, stale/partial links, wrong identity
  inheritance, stuck notes, stranded SysEx buffers, wrong-speed audio, reset
  storms, or persistent xruns;
- if the kernel, permissions, ALSA, PipeWire, or WirePlumber never exposes a
  usable endpoint, diagnostics name that exact failed layer.

Software cannot recover a device that its host subsystem never publishes.
That is the only boundary to “no exceptions.”

## MIDI: complete native design

### Failure in the current implementation

`alsa_midi_init()` builds `srcs`/`dests` once. Those arrays move with
`realloc`, while callers retain element pointers. WinMM then snapshots driver
counts and a device-ID translation array for the process lifetime.

Patch 0028 listens for announce events in `rec_thread_proc`, but that thread
is created only when the first MIDI input starts. Therefore it is absent:

- before any input is opened;
- for an output-only Live session;
- when WinMM starts with zero endpoints;
- after ALSA was unavailable during initial initialization.

This is more fundamental than the prototype's fixed table size. The topology
monitor must be independent of the MIDI data path.

### Data model

Use permanent heap records and replaceable dense snapshots. Records are freed
only at driver shutdown, so open handles never point into a moving array.

```c
struct midi_endpoint {
    uint32_t token;              /* nonzero; monotonically allocated; not reused */
    struct endpoint_key key;
    enum direction direction;

    snd_seq_addr_t current_addr; /* binding, never identity */
    bool online;
    bool identity_ambiguous;
    MIDIINCAPSW or MIDIOUTCAPSW caps;

    pthread_mutex_t lock;         /* open/data state, never held for callbacks */
    struct open_state open;      /* callback, local port, requested started state */
    struct sysex_state sysex;
    uint8_t active_notes[16][16];
    uint16_t sustain_channels;
};

struct midi_catalog {
    pthread_rwlock_t lock;
    list<midi_endpoint *> records;
    midi_endpoint **inputs;      /* current online dense snapshot */
    size_t input_count;
    midi_endpoint **outputs;
    size_t output_count;
    uint64_t generation;
};
```

Snapshot order is permanent token order. Numeric WinMM IDs are current dense
indices and may compact; an already-open handle routes by token, not by that
index.

### Identity

For a kernel ALSA client, obtain its ALSA card and correlate it to sysfs. Match
strongest first:

1. USB vendor/product + serial + interface + port ordinal/direction;
2. when serial is absent, vendor/product + canonical physical bus path +
   interface + ordinal/direction;
3. ALSA card ID/long name + port name/ordinal/direction;
4. for user/virtual clients, client type/name + port name/ordinal/direction.

An ALSA client number, PipeWire global ID, display name, or first directory
entry is never identity. Exact current address may match during a single
generation, but never across disappearance.

If more than one offline record matches a weak key, publish every endpoint but
do not transfer an existing open handle to an arbitrary one. Report
`ambiguous identity`. Identical serial-less devices that both move ports have
no knowable semantic identity; persistent user aliases/proxy slots are the
honest resolution.

PR 152's public Windows device-interface support may reuse the same sysfs
lookup. Its public interface path may contain the current ALSA card/port;
winealsa's internal recovery key must not.

### Dedicated topology monitor

Subscribe before the first full scan, keep the monitor alive from first WinMM
initialization through driver release, and retry if ALSA is initially absent.

```c
alsa_midi_init_once():
    initialize an empty catalog and notification queue
    start topology_thread even when snd_seq_open("default") currently fails
    return success with zero endpoints

topology_thread():
    while not shutting_down:
        if topology_seq is absent:
            open an independent nonblocking SND_SEQ_OPEN_INPUT handle
            on failure:
                report ALSA layer unavailable
                retry with bounded 250 ms -> 2 s backoff
                continue
            create a private input port
            subscribe that port to System Announce 0:1
            request_rescan()

        poll topology_seq and cancel_fd
        if sequencer fails:
            close topology_seq
            mark every endpoint offline through reconcile(empty)
            continue

        drain CLIENT/PORT START, EXIT, and CHANGE events
        if any topology event arrived:
            coalesce for at most 50 ms quiet / 250 ms absolute
            request_rescan()
```

The monitor cannot share `midi_seq` or its port with the record thread: either
consumer could steal announce events, and output-only/no-input operation would
remain broken.

Every event causes a full ALSA port rescan. Do not reconstruct composite
devices one event at a time; ALSA publishes their clients and ports in bursts.

```c
reconcile_full_alsa_topology():
    observed = enumerate every exportable ALSA port
    exclude System and every Wine-owned monitor/data port by client metadata,
        not only the literal name "WINE midi driver"
    derive endpoint_key, direction, capabilities, and semantic ordinal

    write_lock(catalog)
    old_inputs = catalog.inputs
    old_outputs = catalog.outputs

    mark all records unseen
    for observation in observed:
        record = exact_current_address_match(observation)
        if none:
            record = unique_identity_match(observation.key)
        if none:
            record = allocate_permanent_record(next_token++, observation.key)
        if weak_match_is_ambiguous:
            do not inherit an open state
            record = allocate_or_match_only_unopened_record()
            record.identity_ambiguous = true
        bind(record, observation.current_addr, observation.caps)
        record.online = true
        mark seen

    for each unseen record:
        record.online = false
        detach_stale_subscription(record)
        clean_up_disconnected_open_record(record)

    build fresh dense input/output pointer arrays from online records
    sort arrays by permanent token
    swap arrays and counts
    catalog.generation++         /* publish generation last under the lock */
    write_unlock(catalog)
    free old snapshot pointer arrays

    reconnect exact returning open records outside the catalog lock
    queue_one_device_change(catalog.generation)
```

No ALSA, Wine, or WinMM lock may be held while invoking a MIDI callback or
broadcasting a Windows message.

### Open-handle behavior

Enumeration operations read the current snapshot. On open, winealsa writes a
small integer token into the driver-instance result that WinMM already passes
through `dwUser`/the Unix call boundary.

```c
MIDM_GETNUMDEVS: return catalog.input_count
MODM_GETNUMDEVS: return catalog.output_count

GETDEVCAPS or OPEN(current_id):
    read_lock(catalog)
    record = snapshot[current_id]
    retain stable record pointer
    read_unlock(catalog)
    if no record or !record->online: return MIDIERR_NODEVICE

OPEN:
    create/attach the record's local ALSA state
    write_uintptr_result(params->user, record->token)

CLOSE/START/STOP/RESET/DATA/LONGDATA/ADDBUFFER:
    record = token_lookup(params->user)
    operate on the stable record, ignoring compacted enumeration IDs
```

The WoW64 thunk must copy an integer token at the caller's pointer width;
never expose a Unix pointer. Opening the same physical direction twice should
continue to follow Wine's current sharing rules.

On disconnect:

- retain the handle and requested input started/stopped state;
- disconnect stale ALSA subscriptions and reject offline output writes with
  `MIDIERR_NODEVICE`;
- return only a partially filled SysEx input header as `MIM_LONGERROR`, reset
  running status/parser state, and retain empty queued buffers;
- emit sustain-off and note-off/all-notes-off cleanup only for tracked active
  input state, through the normal callback queue;
- on an exact unambiguous return, recreate the subscription and resume the
  prior requested state.

See [MIM_LONGERROR](https://learn.microsoft.com/en-us/windows/win32/multimedia/mim-longerror).

### Refreshable WinMM MIDI maps

Wave and mixer mappings remain untouched. MIDI counts and numeric lookups
refresh from each lower driver. Mapping descriptors are individually allocated
and pointer-stable; the current dense vector contains pointers.

```c
MMDRV_RefreshMidi(type):
    for every non-mapper MIDI driver:
        count = driver(GETNUMDEVS)
        compute its current dense range

    lock(type)
    build/grow pointer vector of stable WINE_MLD descriptors
    fill current logical id, lower driver id, driver index, and type
    publish current vector/count last
    unlock(type)

MMDRV_GetNum(MIDIIN or MIDIOUT):
    MMDRV_RefreshMidi(type)
    return current_count

MMDRV_Get(numeric_midi_id):
    MMDRV_RefreshMidi(type)
    snapshot mapping fields under lock
    return current mapping

MMDRV_Open(numeric_mapping):
    refresh and copy its current lower-driver fields
    allocate a separate handle WINE_MLD
    call lower OPEN
    retain returned winealsa token in dwDriverInstance

MMDRV_Message(open_handle):
    bypass current-count rejection
    pass the captured lower driver and stable token

MMDRV_Message(numeric_mapping):
    snapshot fields, unlock, then call the lower driver
```

This preserves `midiInGetID()` as the application-visible ID captured at open
while allowing the lower driver to follow the stable record. It also fixes
shrink, growth, and concurrent enumeration instead of reserving 32 slots.

`midiInGetNumDevs`/`midiOutGetNumDevs` are specified as the current number of
devices, so offline records do not remain in the dense list. See
[midiInGetNumDevs](https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-midiingetnumdevs).

### Notification

After the new snapshots and counts are published, queue one notification per
generation through the existing mmdevapi MIDI notify thread:

```c
enum midi_notify_kind { MIDI_CALLBACK, MIDI_TOPOLOGY_CHANGED };

PE notify thread, on MIDI_TOPOLOGY_CHANGED:
    recipients = BSM_APPLICATIONS
    BroadcastSystemMessageW(BSF_POSTMESSAGE, &recipients,
                            WM_DEVICECHANGE, DBT_DEVNODES_CHANGED, 0)
```

`DBT_DEVNODES_CHANGED` tells list owners to refresh and carries no cross-
process pointer. Coalesce duplicate events and never broadcast before
publication. A real interface-arrival PnP object is not necessary unless the
Live gate proves otherwise; notification alone is never used to paper over a
stale WinMM table.

References:

- [WM_DEVICECHANGE](https://learn.microsoft.com/en-us/windows/win32/devio/wm-devicechange)
- [DBT_DEVNODES_CHANGED](https://learn.microsoft.com/en-us/windows/win32/devio/dbt-devnodes-changed)
- [Wine plugplay broadcast pattern](https://github.com/wine-mirror/wine/blob/8da89f8493b21ebfbe344a54dbef0cde23c7ea59/programs/plugplay/main.c#L142-L152)

### Compatibility boundary

[Wine 11.16](https://github.com/wine-mirror/wine/commit/8da89f8493b21ebfbe344a54dbef0cde23c7ea59)
still has the same one-shot winealsa inventory and WinMM cache as the project's
11.13 base. `winebus.sys` monitors HID/input objects; it does not turn ALSA
sequencer ports into PnP MIDI devices.

Live imports and uses WinMM, but its internal post-notification behavior must
be measured. Ableton documents connected controllers as automatically
detected in [Live's MIDI Settings](https://help.ableton.com/hc/en-us/articles/209774205-Live-s-MIDI-Settings),
so real Live behavior is the compatibility gate. If WinMM
count/caps/open/data and `WM_DEVICECHANGE` are correct yet Live does not
re-enumerate, add a supervised fixed bank of persistent ALSA
sequencer ports before Live starts and route hardware behind them. Use
multiple named slots, hide duplicate physical ports, preserve SysEx/clock,
and expose aliases for identical devices. Do not adopt that facade before the
host gate fails: it loses native names and adds a broker lifetime.

`midimap` snapshots outputs once per mapper open family and DirectMusic has a
separate per-object list. Instrument Live first. If Live actually selects
`MIDI_MAPPER`, rebuild mapper state per open; if it relies on DirectMusic
enumeration, refresh that object's list. Do not widen the first patch on
speculation.

## Audio: complete PipeASIO design

### Failure in the current implementation

PipeASIO already observes Node/Port additions and removals, but it stores
manual links only as raw `pw_proxy *` objects and selected devices as current
numeric global IDs. `global_remove` deletes cached objects without reconciling
affected routes. Links are created once in `CreateBuffers`. There is no core
error listener or backend reconstruction, and the settings panel takes a
one-shot `pw-dump` snapshot.

PipeASIO is a manually linked duplex DSP filter. It is not a WirePlumber-
managed application stream, so follow-default/reconnect policy cannot restore
its links. Converting it into a smart filter is larger and still leaves ASIO
channel/clock policy inside the driver.

### Minimal state

Retain the current filter, local PipeWire ports, ASIO buffers, and callbacks.
Replace anonymous links with persistent route intents.

```c
enum target_mode { TARGET_DISABLED, TARGET_EXPLICIT, TARGET_AUTOMATIC };
enum route_state { WAIT_TARGET, WAIT_PORTS, LINKING, READY, INCOMPATIBLE };
enum backend_state { SERVER_DOWN, RECONNECTING, ONLINE, CLOSING };

struct stable_device_identity {
    char node_name[];             /* exact configured identity when stable */
    char device_serial[];
    char vendor_product[];
    char bus_path[];
    char alsa_path[];
};

struct audio_route {
    audio_port_t *local;          /* stable ASIO-facing port */
    enum direction direction;
    unsigned asio_channel;

    enum target_mode mode;
    char selected_node_name[];
    struct stable_device_identity wanted_device;
    char remote_port_name[];
    char audio_channel[];
    unsigned semantic_ordinal;

    uint64_t generation;
    enum route_state state;
    uint32_t remote_node_id;      /* current binding only */
    uint32_t remote_port_id;      /* current binding only */
    struct pw_proxy *link_proxy;
    struct spa_hook proxy_listener;
    struct spa_hook link_listener;
};

struct audio_client {
    ...existing fields...
    enum backend_state backend;
    uint64_t topology_generation;
    uint64_t reconciled_generation;
    struct direction_state playback, capture;
    vector<audio_route> routes;
    serialized recovery worker state;
};
```

Cache PipeWire Device objects as well as Node/Port objects and associate them
through `device.id`. `node.name` is the first exact explicit-selection key.
Use hardware `device.serial` with vendor/product, then bus/ALSA path, then
semantic port channel/name. `object.id`, `object.serial`, registry globals,
and display descriptions are bindings, not persistent physical identity.

For an explicit target, disappearance enters `WAIT_TARGET`; never steal a
same-named or default device. Automatic mode retains the project's existing
playback-first selection and same-card capture preference. “Follow default”
can be added as an explicit policy later if the UI exposes it; it is not
required to repair an explicitly selected interface.

### Topology reconciliation

Registry callbacks update cache and state only. Use `pw_core_sync` as the
completion boundary for a publication burst rather than an arbitrary sleep.

```c
on_registry_add_or_remove(global):
    update Device/Node/Port cache
    topology_generation++

    if removed object backs a route:
        mark whole direction not ready immediately
        destroy that route generation's links
        gate capture to silence and playback to discard

    reconcile_seq = pw_core_sync(core)

on_core_done(reconcile_seq):
    reconcile(topology_generation)

reconcile(generation):
    reconcile_direction(playback, generation) /* clock leader first */
    reconcile_direction(capture, generation)  /* preserve follower policy */

reconcile_direction(direction, generation):
    destroy stale-generation links
    target = resolve configured policy and stable identity
    if target absent:
        state = WAIT_TARGET
        return

    mapping = resolve every active ASIO channel by semantic port identity
    if registry burst is incomplete:
        state = WAIT_PORTS
        schedule another core sync
        return
    if mapping is ambiguous or host geometry incompatible:
        state = INCOMPATIBLE
        report exact reason
        return

    create one current link binding for each route
    attach pw_proxy_events and pw_link_events to every link
    state = LINKING

on_link_state(PAUSED or ACTIVE):
    if every route in the direction belongs to this generation and succeeded:
        clear and recompute per-port/direction latency
        direction.ready = true
        state = READY

on_link_removed_or_error(route):
    direction.ready = false
    destroy the route generation
    request core sync and reconciliation
```

A non-null link-factory proxy is not success; link publication and state are
asynchronous. Use generation checks to ignore late callbacks from a removed
graph. Never expose a partially linked multichannel direction.

The realtime callback performs only an atomic readiness read:

```c
if (!capture.ready)
    zero every ASIO input buffer;
else
    consume capture normally;

if (!playback.ready)
    discard/zero playback safely;
else
    produce playback normally;
```

Compatible returns reuse the same ASIO channel objects and heap buffers and
relink directly. Recompute latency from per-port values on every link/param
change so a lower-latency returning target does not retain an old maximum.

Request one debounced `kAsioResetRequest` only when sample rate, quantum,
channel geometry, or buffer contract cannot be preserved. A reset is a host
request, not proof of recovery; never reset-loop while the target is absent.

### Configuration and settings panel

Add one internal route update operation:

```c
audio_update_route_policy(client, direction, selected_node_name, auto_connect):
    update target mode and desired stable identity
    invalidate only that direction's links
    request core sync and reconcile
```

Routing-only configuration changes call this directly. Existing reset logic
remains for rate, quantum, channel count, and buffer-layout changes. The
settings dialog refreshes its asynchronous `pw-dump` snapshot once per second
while open, preserves an unavailable saved selection, and never blocks its UI
thread.

With `auto_connect=false`, PipeASIO must not recreate links deleted by a user
patchbay. With it enabled, restore only links represented by PipeASIO's route
intents.

### PipeWire delayed startup and restart

Add `pw_core_events.error` and treat filter `UNCONNECTED`/`ERROR` as a backend
failure. Recovery is serialized outside the realtime thread.

```c
on_core_error_or_filter_disconnect():
    atomically mark both directions not ready
    backend = SERVER_DOWN
    wake recovery_worker

recovery_worker():
    lock lifecycle against Activate, DisposeBuffers, and Close
    while backend != CLOSING:
        preserve ASIO buffers, route intents, callbacks, and requested running state
        destroy links, filter, registries, and cores in dependency order
        attempt both PipeWire connections with bounded retry backoff
        if unavailable:
            report PipeWire layer unavailable
            continue
        attach error/registry/filter listeners
        perform initial pw_core_sync and version validation
        rebuild the same filter and local PipeWire ports
        reconcile saved route intents
        backend = ONLINE
        break
    unlock lifecycle

Close():
    backend = CLOSING
    cancel and join recovery_worker
    free client state
```

`IASIO::Init` may create a `SERVER_DOWN` client, and `CreateBuffers` may keep
the host buffers and desired run state while PipeWire is absent. The real Live
gate must establish whether Live tolerates the callback gap during a complete
daemon outage. If it does not, issue one reset only after the rebuilt backend
is usable. Do not add a synthetic emergency clock unless that test proves it
necessary.

References:

- [PipeWire core events](https://docs.pipewire.org/structpw__core__events.html)
- [PipeWire properties](https://docs.pipewire.org/page_man_pipewire-props_7.html)
- [PipeWire link factory](https://pipewire.pages.freedesktop.org/pipewire/page_module_link_factory.html)
- [WirePlumber smart filters](https://pipewire.pages.freedesktop.org/wireplumber/policies/smart_filters.html)

## Adversarial review and consensus

| Proposal or challenge | Failure | Resolution |
|---|---|---|
| Add MIDI ports on each `PORT_START` | Composite devices arrive in bursts; events race scans and duplicate/reorder ports. | Subscribe first, coalesce, and diff a full ALSA snapshot. |
| Protect the existing realloc arrays with a mutex | Open handles and callbacks outlive the lock and retain moved pointers. | Permanent endpoint records plus replaceable dense pointer snapshots. |
| Keep removed MIDI slots forever | Violates current-device enumeration and eventually exhausts/duplicates slots. | Offline permanent records for handles; online dense snapshots for enumeration. |
| Match MIDI by display name/client ID | Names duplicate and IDs churn. | Hardware/card identity hierarchy; never ambiguous inheritance. |
| Broadcast device change only | Live may requery, but stale winealsa/WinMM still cannot expose the device. | Publish correct tables first, then notify. |
| Native WinMM works but Live ignores it | Correct driver behavior could remain invisible in the host. | Instrument real Live; only then enable persistent proxy slots. |
| Ask udev to trigger MIDI recovery | Too early, USB-only, misses virtual/Bluetooth/network endpoints. | ALSA System Announce is authority; udev enriches identity/diagnostics only. |
| Persist PipeWire IDs | IDs change and may be reused after device/daemon restart. | Persist stable device/semantic port identity; IDs are bindings only. |
| WirePlumber will restore PipeASIO links | PipeASIO's manual duplex filter is not a managed app stream. | PipeASIO owns its route intents and links. |
| Reset ASIO on every graph change | Reset can be ignored/deferred, causes storms/dialogs, and fires while absent. | Direct relink compatible topology; one reset only for incompatible host contracts. |
| Relink as soon as the first port appears | Produces partial/wrong multichannel graphs. | Registry generation + `pw_core_sync` + all-channel readiness gate. |
| Fall back to a same-named audio device | Can steal audio to the wrong interface. | Explicit selection waits for exact identity; ambiguity is surfaced. |
| External graph guardian | Cannot safely own ASIO channel, clock, reset, and shutdown lifetime. | Diagnostic/readiness observer only. |
| Full PipeWire daemon restart | Existing core/filter objects are dead; relink alone cannot work. | Rebuild backend while preserving ASIO-facing state; gate Live behavior. |

Consensus: native dynamic MIDI publication and native PipeASIO route recovery
cover the real ownership boundaries with the least machinery. Persistent MIDI
slots are a measured host-compatibility fallback, not the default design.

## Minimal patch series

### Wine patch A: dynamic winealsa catalog

Touch only:

- `dlls/winealsa.drv/alsamidi.c`;
- `dlls/mmdevapi/unixlib.h`;
- `dlls/mmdevapi/main.c`;
- focused winealsa tests where practical.

Replace patch 0028's name-only event handler with the dedicated monitor,
stable catalog, identity match, disconnect cleanup, open-handle token, and
generation-coalesced topology notification. Keep its proven reconnect intent;
do not stack a second independent announce subscriber.

### Wine patch B: refreshable WinMM MIDI map

Touch only:

- `dlls/winmm/lolvldrv.c` and its private header;
- focused WinMM tests.

Leave wave/mixer mappings and speculative DirectMusic changes alone. Refresh
MIDI counts and numeric lookups, publish pointer-stable mappings, and preserve
open handles through their lower-driver token.

### PipeASIO patch 0012: persistent route intent

Touch primarily:

- `src/audio.c`/its header for Device cache, route/link state, reconciliation,
  readiness, and backend recovery;
- `src/asio.c` for direct routing updates and bounded incompatible reset;
- settings enumerator/dialog for periodic device refresh;
- existing PipeASIO unit/integration tests.

Do not add another process or policy engine.

### Repository tests and audit

Extend `midiwatch` so it initializes with zero devices, creates a top-level
window, logs device-change messages, repeatedly enumerates counts/caps, and
opens a newly appearing endpoint without holding a MIDI input open. Extend
`fakectl` for input/output/duplex, multiple ports, duplicate names, SysEx,
clock, and deterministic identity labels. Add PipeASIO state-machine and
private-PipeWire graph tests. Update patch fingerprints/build audit only when
the implementation patches are final.

The transplanted August patches numbered 0100/0101 apply textually on the
current Wine series, but they remain prototypes and must not be added to the
release manifest: their fixed slots, lifetime counts, name identity, and
input-thread monitor cannot satisfy this design. Their numbers also overlap
future current-main work and should be assigned only at implementation time.

## Verification and release gate

### MIDI automation

1. Initialize WinMM with no sequencer endpoint, then add one. Assert count,
   caps, notification, open, and data within two seconds.
2. Repeat after wineserver but before Live MIDI initialization, after Live
   start, and after engine activation.
3. Test input, output-only, duplex, multiport, composite USB, duplicate names,
   no serial, a device moved to another USB port, and two identical devices.
4. Keep an input/output handle open across removal and a changed ALSA client
   ID. Assert exact reattachment within five seconds and no ID switch to an
   unrelated endpoint.
5. Remove during partial SysEx, held notes, sustain, and clock; verify buffer
   completion and cleanup semantics.
6. Start with ALSA unavailable, then make it available. Restart PipeWire's
   ALSA MIDI bridge separately.
7. Race GetNum/GetCaps/Open/Close with at least 100 add/remove cycles under
   native 64-bit and WoW64, then run a performance-length soak.

### Audio automation

1. Unit-test every Device/Node/Port event order, stale generation, partial
   graph, duplicate identity, link removal/error, profile change, latency
   decrease, and shutdown/recovery race.
2. In a private PipeWire graph, remove/recreate source and sink under new
   globals. Assert full silence while absent, exactly one complete link group,
   resumption without reset for compatible topology, and stable ASIO buffers.
3. Test explicit selection, automatic/default selection, separate capture and
   playback devices/clock domains, manual link deletion with auto-connect both
   on and off, and settings panel refresh within two seconds.
4. Kill/restart private PipeWire and WirePlumber instances. Assert bounded
   recovery or one post-readiness reset if the host requires it.
5. Run at least 100 topology cycles and a performance-length soak with xrun,
   rate, quantum, latency, duplicate-link, and stale-object instrumentation.

### Host/hardware gate

The final gate is an actual supported Ableton Live build and real USB MIDI and
audio hardware, with playing and recording active. Driver-only probes and
generic ASIO hosts are necessary but insufficient.

Instrument WinMM first. If a newly connected controller appears, opens, and
moves data in the probe but not in Live after notification, record that as the
single evidence needed for the persistent MIDI facade. For audio, distinguish
ordinary interface unplug/replug (direct relink) from complete PipeWire daemon
loss (host callback-gap compatibility).

Do not describe hotplug as automatic in release documentation until every
applicable gate passes. On failure, logs must identify: kernel/permission,
ALSA sequencer, PipeWire registry, PipeASIO route state, winealsa catalog,
WinMM mapping, notification, or Live host cache.
