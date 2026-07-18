# Ableton product matrix: the ten supported Live products (Live 11/12 x Suite/
# Standard/Intro/Lite/Trial) and the metadata derived mechanically from the exe:
#   folder   = exe minus 'Ableton ' and '.exe'      ("Live 12 Suite")
#   WM class = lowercase exe                         ("ableton live 12 suite.exe")
#   icon     = <install>/Resources/Icons/live_<edition>.ico (generic.ico fallback)
# Source this file, then:
#   ableton_profile_for MAJOR EDITION  — derive one matrix product's metadata
#   ableton_profile_detect EXE_PATH    — validate a discovered exe against the matrix
#   ableton_profile_list               — print "MAJOR EDITION<TAB>EXE_PATH" per install
# Detection refuses layouts outside the matrix (unknown majors/editions, renamed exes)
# instead of guessing; WINEPREFIX (default ~/.wine-ableton) locates paths and icons.

ABLETON_LIVE_VERSIONS="11 12"
ABLETON_LIVE_EDITIONS="Suite Standard Intro Lite Trial"

# ableton_profile_for MAJOR EDITION — set ABLETON_{MAJOR,EDITION,EXE,FOLDER,
# EXE_PATH,WM_CLASS,ICON} for one matrix product. Returns 1 off the matrix.
ableton_profile_for() {
    local major="$1" edition="$2" known=1 m e
    for m in $ABLETON_LIVE_VERSIONS; do
        for e in $ABLETON_LIVE_EDITIONS; do
            [ "$m $e" = "$major $edition" ] && known=0
        done
    done
    [ "$known" -eq 0 ] || return 1
    local prefix="${WINEPREFIX:-$HOME/.wine-ableton}"
    ABLETON_MAJOR="$major"
    ABLETON_EDITION="$edition"
    ABLETON_EXE="Ableton Live $major $edition.exe"
    ABLETON_FOLDER="Live $major $edition"
    ABLETON_EXE_PATH="$prefix/drive_c/ProgramData/Ableton/$ABLETON_FOLDER/Program/$ABLETON_EXE"
    ABLETON_WM_CLASS="$(printf '%s' "$ABLETON_EXE" | tr '[:upper:]' '[:lower:]')"
    local icon_dir="$prefix/drive_c/ProgramData/Ableton/$ABLETON_FOLDER/Resources/Icons"
    ABLETON_ICON="$icon_dir/live_$(printf '%s' "$edition" | tr '[:upper:]' '[:lower:]').ico"
    [ -f "$ABLETON_ICON" ] || ABLETON_ICON="$icon_dir/generic.ico"
    return 0
}

# ableton_profile_detect EXE_PATH — validate a discovered exe against the matrix and
# set the same variables as ableton_profile_for (plus ABLETON_INSTALL_DIR, the outer
# folder as found on disk). The exe basename must be a matrix product exactly and sit
# under a Program dir; the outer folder only needs to name a known product — a strict
# folder == exe-derived equality rejects valid installs, so the exe
# is the product identity and the folder is not required to match it character-for-
# character. Returns 1 on any layout the matrix does not know: never guess.
ableton_profile_detect() {
    local path="$1" exe folder
    exe="$(basename "$path")"
    [ "$(basename "$(dirname "$path")")" = Program ] || return 1
    folder="$(basename "$(dirname "$(dirname "$path")")")"
    # Product identity comes from the exe: "Ableton Live <major> <edition>.exe".
    case "$exe" in
        "Ableton Live "*" "*.exe) ;;
        *) return 1 ;;
    esac
    local major edition
    major="$(printf '%s' "$exe" | awk '{print $3}')"
    edition="$(printf '%s' "${exe%.exe}" | awk '{print $4}')"
    ableton_profile_for "$major" "$edition" || return 1
    # Outer-folder validation: it must itself name a known product ("Live <major>
    # <edition>"), but is not required to equal the exe-derived folder character-
    # for-character (relaxed path-equality — e.g. "Live 12 Suite Beta" passes).
    local fmajor fedition fm fe fok=1
    fmajor="$(printf '%s' "$folder" | awk '{print $2}')"
    fedition="$(printf '%s' "$folder" | awk '{print $3}')"
    for fm in $ABLETON_LIVE_VERSIONS; do
        for fe in $ABLETON_LIVE_EDITIONS; do
            [ "$fm $fe" = "$fmajor $fedition" ] && fok=0
        done
    done
    [ "$fok" -eq 0 ] || return 1
    ABLETON_INSTALL_DIR="$(dirname "$(dirname "$path")")"
    ABLETON_EXE_PATH="$path"
    local icon_dir="$ABLETON_INSTALL_DIR/Resources/Icons"
    ABLETON_ICON="$icon_dir/live_$(printf '%s' "$ABLETON_EDITION" | tr '[:upper:]' '[:lower:]').ico"
    [ -f "$ABLETON_ICON" ] || ABLETON_ICON="$icon_dir/generic.ico"
    return 0
}

# ableton_profile_list — one "MAJOR EDITION<TAB>EXE_PATH" line per discovered install
# in the prefix, version-sorted; layouts the matrix rejects are skipped.
ableton_profile_list() {
    local prefix="${WINEPREFIX:-$HOME/.wine-ableton}" f
    ls "$prefix"/drive_c/ProgramData/Ableton/*/Program/"Ableton Live"*.exe 2>/dev/null \
        | sort -V | while IFS= read -r f; do
            if ableton_profile_detect "$f"; then
                printf '%s %s\t%s\n' "$ABLETON_MAJOR" "$ABLETON_EDITION" "$f"
            fi
        done
}
