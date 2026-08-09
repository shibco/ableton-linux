#!/usr/bin/env python3
"""Audit which fonts Max for Live devices request, and which the prefix cannot resolve.

An unresolvable font is not cosmetic. MaxPlug's font fallback chain terminates at
"Bitstream Vera Sans" (the string is hardcoded in MaxPlug.dll). When both the
requested face and that terminal fallback are missing, MaxPlug parks Live's UI
thread on a condition variable and never signals it - a permanent, deterministic
hang with audio still running. See
notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md

Usage:
    tools/m4l-font-audit.py [--prefix DIR] [--verbose] [PATH ...]

With no PATH, scans the usual Ableton locations. Exit status is 1 if any
requested font is unresolvable, so this works as a CI / post-setup check.
"""

import argparse
import os
import subprocess
import re
import subprocess
import sys
from collections import defaultdict

# Style words that may be appended to a family name in a Max "fontname" field,
# e.g. "Arial Bold", "Ableton Sans Medium Regular". Stripped progressively when
# an exact match fails, so "Arial Bold" can still resolve against family "Arial".
STYLE_WORDS = {
    "regular", "bold", "italic", "oblique", "light", "medium", "book",
    "semibold", "demibold", "black", "heavy", "thin", "extralight",
    "ultralight", "condensed", "narrow", "roman",
}

DEFAULT_SCAN_DIRS = [
    "~/Music/Ableton",
    "~/storage-1tb/ableton-factory",
    "{prefix}/drive_c/ProgramData/Ableton",
]

FONT_DIRS = [
    "{prefix}/drive_c/windows/Fonts",
    "{prefix}/drive_c/ProgramData/Ableton/*/Resources/Max/resources/fonts",
]

FONTNAME_RE = re.compile(rb'"(?:default_)?fontname"\s*:\s*"([^"]{1,120})"')

# Max logical font names, written in angle brackets. These are resolved inside
# MaxPlug (the literal "<Monospaced>" is present in MaxPlug.dll) rather than
# looked up as real family names, so they are not fallback-chain triggers.
LOGICAL_RE = re.compile(r"^<.*>$")

# The terminal entries of MaxPlug's own font fallback chain, hardcoded in
# MaxPlug.dll. Whether these resolve is what separates "wrong typeface" from
# "Live hangs": a failed primary lookup is harmless as long as the chain still
# has somewhere to land.
TERMINAL_FALLBACKS = ("Bitstream Vera Sans", "Bitstream Vera Serif",
                      "Bitstream Vera Sans Mono")


def norm(s):
    return " ".join(s.lower().split())


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return p.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def probe_available(prefix, verbose=False):
    """Ask Wine directly which families it enumerates - the authoritative answer.

    Inferring this from fc-list/fc-scan is unreliable and has produced two wrong
    verdicts already: font files sitting in the prefix Fonts directory are NOT
    enumerated until they are registered under the HKLM Fonts key, and
    FontSubstitutes aliases never appear at all. fontprobe.exe calls the same
    EnumFontFamiliesEx that Max uses, so it cannot disagree with reality.
    """
    exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fontprobe.exe")
    if not os.path.exists(exe):
        return None
    wine = os.path.join(os.path.expanduser(os.environ.get(
        "WORKS_RUNTIME", _resolved_root())), "bin/wine")
    if not os.path.exists(wine):
        wine = "wine"
    env = dict(os.environ, WINEPREFIX=prefix, WINEDEBUG="-all")
    try:
        p = subprocess.run([wine, exe], capture_output=True, text=True,
                           timeout=180, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    names = {norm(l) for l in (ln.strip() for ln in p.stdout.splitlines())
             if l and not l.endswith("families enumerated")}
    if verbose:
        print(f"    {len(names)} family name(s) from fontprobe.exe "
              f"(authoritative)", file=sys.stderr)
    return names or None


def scan_font_files(paths):
    """Family and full names inside the given font files, via fontconfig."""
    if not paths:
        return set()
    out = run(["fc-scan", "--format", "%{family}|%{fullname}\n"] + paths)
    names = set()
    for line in out.splitlines():
        for half in line.split("|"):
            for part in half.split(","):
                if part.strip():
                    names.add(norm(part))
    return names


def collect_bundled(prefix, verbose=False):
    """Faces Max ships and loads privately at runtime, e.g. Ableton Sans, Lato.

    These never appear in another process's EnumFontFamiliesEx output, so they
    must be added on top of the fontprobe result rather than inferred from it.
    """
    import glob
    files = []
    for d in glob.glob(os.path.join(
            prefix, "drive_c/ProgramData/Ableton/*/Resources/Max/resources/fonts")):
        files += [os.path.join(d, f) for f in os.listdir(d)
                  if f.lower().endswith((".ttf", ".otf", ".ttc"))]
    names = scan_font_files(files)
    if verbose:
        print(f"    {len(names)} name(s) from Max's private font bundle "
              f"({len(files)} files)", file=sys.stderr)
    return names


def collect_available(prefix, verbose=False):
    """Every font name Wine could plausibly match, from all three sources."""
    names, sources = set(), defaultdict(int)

    # 1. System fonts, via fontconfig - Wine reads these too.
    # NOTE: do not pass an element (e.g. "file") alongside --format; fc-list
    # then emits one empty line per font and the whole set is silently lost.
    for fmt in ("%{family}\n", "%{fullname}\n"):
        for line in run(["fc-list", "--format", fmt]).splitlines():
            for part in line.split(","):
                if part.strip():
                    names.add(norm(part))
                    sources["system"] += 1

    # 2. Fonts on disk in the prefix, and Max's own bundled fonts. These are not
    #    necessarily known to fontconfig, so scan the files directly.
    import glob
    for pat in FONT_DIRS:
        for d in glob.glob(pat.format(prefix=prefix)):
            files = [os.path.join(d, f) for f in os.listdir(d)
                     if f.lower().endswith((".ttf", ".otf", ".ttc"))]
            if not files:
                continue
            out = run(["fc-scan", "--format", "%{family}|%{fullname}\n"] + files)
            for line in out.splitlines():
                for half in line.split("|"):
                    for part in half.split(","):
                        if part.strip():
                            names.add(norm(part))
                            sources[d] += 1
    if verbose:
        for k, v in sources.items():
            print(f"    {v:5d} name(s) from {k}", file=sys.stderr)
    return names


def collect_substitutes(prefix):
    """HKLM FontSubstitutes: requested name -> replacement name."""
    subs = {}
    reg = os.path.join(prefix, "system.reg")
    if not os.path.exists(reg):
        return subs
    in_key = False
    with open(reg, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("["):
                in_key = "FontSubstitutes" in line
                continue
            if in_key:
                m = re.match(r'"([^"]+)"\s*=\s*"([^"]*)"', line)
                if m:
                    subs[norm(m.group(1))] = norm(m.group(2))
    return subs


def resolves(name, available, subs, _depth=0):
    """Can Max satisfy this font request?

    IMPORTANT: FontSubstitutes is deliberately NOT consulted. It only redirects
    GDI CreateFontIndirect calls; it does not add names to EnumFontFamilies
    output. Max enumerates families itself (hence its "system has N typefaces"
    log line) and matches against that list, so a substitution is invisible to
    it. Verified empirically 2026-07-29: aliasing both "Geneva" and "Bitstream
    Vera Sans" to DejaVu changed nothing - Live still hung, and Max still logged
    both as not found. Only a real font file with the requested family name
    works. `subs` is accepted and reported for information only.
    """
    n = norm(name)
    if n in available:
        return True
    # Charset-suffixed forms like "Arial CE,238".
    if "," in n and _depth < 4 and resolves(n.split(",")[0], available, subs,
                                           _depth + 1):
        return True
    # Progressively strip trailing style words: "arial bold italic" -> "arial".
    parts = n.split()
    while len(parts) > 1 and parts[-1] in STYLE_WORDS:
        parts.pop()
        if " ".join(parts) in available:
            return True
    return False


def scan_devices(paths):
    """device path -> {font name: count}"""
    out = {}
    for root in paths:
        if os.path.isfile(root) and root.lower().endswith(".amxd"):
            files = [root]
        else:
            files = []
            for dirpath, _dirs, names in os.walk(root):
                files += [os.path.join(dirpath, n) for n in names
                          if n.lower().endswith(".amxd")]
        for f in files:
            try:
                with open(f, "rb") as fh:
                    blob = fh.read()
            except OSError:
                continue
            counts = defaultdict(int)
            for m in FONTNAME_RE.finditer(blob):
                try:
                    counts[m.group(1).decode("utf-8")] += 1
                except UnicodeDecodeError:
                    continue
            if counts:
                out[f] = dict(counts)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*", help="dirs or .amxd files to scan")
    ap.add_argument("--prefix", default=os.environ.get(
        "WORKS_PLUG", os.path.expanduser("~/works/plugs/studio")))
    ap.add_argument("--verbose", "-v", action="store_true")
    ap.add_argument("--no-probe", action="store_true",
                    help="skip fontprobe.exe and use the fc-list estimate")
    args = ap.parse_args()

    prefix = os.path.expanduser(args.prefix)
    if not os.path.isdir(prefix):
        print(f"!! prefix not found: {prefix}", file=sys.stderr)
        return 2

    print(f"prefix: {prefix}")
    available, how = None, "fontprobe.exe + Max's private bundle"
    if not args.no_probe:
        available = probe_available(prefix, args.verbose)
    if available is not None:
        # fontprobe reports what a *separate* process enumerates. Max also loads
        # its own bundled faces privately (AddFontResourceEx), so those are
        # visible to Max while invisible to any other process - without this
        # union, the ~60 devices using "Ableton Sans Medium" look broken when
        # they demonstrably are not.
        bundled = collect_bundled(prefix, args.verbose)
        available |= bundled
    if available is None:
        available = collect_available(prefix, args.verbose)
        how = "fc-list/fc-scan estimate - NOT authoritative"
        if not args.no_probe:
            print("!! fontprobe.exe unavailable; falling back to an estimate that\n"
                  "   cannot see registration state. Build it for exact results:\n"
                  "   x86_64-w64-mingw32-gcc -O2 -o tools/fontprobe.exe "
                  "tools/fontprobe.c -lgdi32")
    subs = collect_substitutes(prefix)
    print(f"resolvable font names: {len(available)} via {how}")
    print(f"FontSubstitutes entries: {len(subs)} (informational - invisible to Max)")

    paths = [os.path.expanduser(p) for p in args.paths] or [
        os.path.expanduser(d.format(prefix=prefix)) for d in DEFAULT_SCAN_DIRS]
    paths = [p for p in paths if os.path.exists(p)]

    devices = scan_devices(paths)
    print(f"devices scanned: {len(devices)}\n")
    if not devices:
        print("no .amxd files found - pass a path explicitly")
        return 2

    # font -> (total requests, set of devices)
    tally = defaultdict(lambda: [0, set()])
    for dev, counts in devices.items():
        for font, n in counts.items():
            tally[font][0] += n
            tally[font][1].add(dev)

    missing, logical = {}, {}
    for f, v in tally.items():
        if LOGICAL_RE.match(f.strip()):
            logical[f] = v
        elif not resolves(f, available, subs):
            missing[f] = v

    print(f"{'FONT':<34} {'REQS':>6} {'DEVICES':>8}  STATUS")
    print("-" * 66)
    for font, (n, devs) in sorted(tally.items(), key=lambda kv: -kv[1][0]):
        status = "MISSING" if font in missing else (
            "logical" if font in logical else "ok")
        print(f"{font:<34} {n:>6} {len(devs):>8}  {status}")

    if logical:
        print(f"\n({len(logical)} logical name(s) skipped - resolved inside "
              f"MaxPlug, not via the font mapper)")

    # Is MaxPlug's fallback chain able to land anywhere? This, not the count of
    # missing primaries, decides whether a device hangs.
    broken_fallbacks = [f for f in TERMINAL_FALLBACKS
                        if not resolves(f, available, subs)]
    print()
    for f in TERMINAL_FALLBACKS:
        ok = f not in broken_fallbacks
        note = ""
        if not ok and norm(f) in subs:
            note = f"  (a FontSubstitutes alias to {subs[norm(f)]!r} exists but " \
                   f"does NOT help Max)"
        print(f"  fallback {f:<26} {'OK' if ok else 'UNRESOLVABLE'}{note}")

    # Packs are commonly installed twice (Factory Packs + a factory mirror), so
    # count distinct device names rather than distinct paths.
    def uniq(devs):
        return sorted({os.path.basename(d)[:-5] for d in devs})

    all_names = {os.path.basename(d)[:-5] for d in devices}
    at_risk = sorted({n for _f, (_c, devs) in missing.items()
                      for n in uniq(devs)})

    if broken_fallbacks:
        print(f"\n=== HANG RISK: fallback chain is BROKEN "
              f"({', '.join(broken_fallbacks)}) ===")
        print(f"{len(missing)} unresolvable font(s) -> {len(at_risk)}"
              f"/{len(all_names)} distinct devices WILL hang Live on load.\n")
    elif missing:
        print(f"\n=== No hang risk: fallback chain is healthy ===")
        print(f"{len(missing)} unresolvable font(s) affect {len(at_risk)}"
              f"/{len(all_names)} devices, but MaxPlug can still land on its\n"
              f"fallback, so these render in a substituted typeface instead of "
              f"hanging.\n")
    else:
        print(f"\nAll {len(tally) - len(logical)} real font requests resolve, "
              "and the fallback chain is healthy.")
        return 0

    for font, (n, devs) in sorted(missing.items(), key=lambda kv: -len(kv[1][1])):
        names = uniq(devs)
        print(f"  {font!r}  ({n} requests, {len(names)} device(s))")
        print("      " + ", ".join(names))

    if broken_fallbacks:
        print("\nFix - the fallback family must actually EXIST as a font file.")
        print("A FontSubstitutes registry alias does NOT work here; Max matches")
        print("against its own font enumeration, which aliases never enter.\n")
        print("  sudo apt install ttf-bitstream-vera      # or your distro's "
              "equivalent\n")
        print("Better, for a self-contained prefix, drop the Vera .ttf files "
              "into:\n")
        print(f"  {os.path.join(prefix, 'drive_c/windows/Fonts')}\n")
        return 1

    print("These render in a substituted typeface. To restore the intended")
    print("typography you would need the real font files; there is no")
    print("registry-only workaround.")
    return 0


if __name__ == "__main__":
    sys.exit(main())


def _resolved_root():
    """Ask the installed resolver where the runtime is.

    The path stopped being a constant when the runtime moved into a store keyed
    by build; works-runtime answers for both layouts.
    """
    try:
        return subprocess.run(["works-runtime", "path"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except Exception:
        return os.path.expanduser("~/works/runtimes/stable")
