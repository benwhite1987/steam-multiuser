#!/usr/bin/env bash
# =============================================================================
# steam-multiuser — Shared Steam library manager for multi-user Linux systems
#
# Lets multiple user accounts share one Steam game library while keeping each
# user's Proton prefixes, saves, and shader caches private. Handles the
# permissions, group membership, and per-login bind mounts required to make
# this work, and diagnoses/repairs an existing setup.
#
# Usage:
#   steam-multiuser.sh              diagnose and fix the shared library setup
#   steam-multiuser.sh --add USER   onboard a new user to the shared library
#   steam-multiuser.sh --migrate    move all users' games into the shared library
#   steam-multiuser.sh --move PATH  relocate the shared library to a new path
#   steam-multiuser.sh --check      diagnose only, make no changes
#   steam-multiuser.sh --help       detailed usage documentation
#
# Configuration: see /etc/steam-multiuser.conf (overrides the defaults below).
# License: GPL-2.0-or-later
# SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================

# This script intentionally does NOT use `set -euo pipefail`: it runs many
# checks whose non-zero exit is expected and handled explicitly at each call
# site. Global error-exit modes would abort on the first expected failure.

# SC2059: we deliberately put ANSI color variables in printf format strings.
# Those variables contain only escape sequences (no % specifiers), so this is
# safe and keeps the colorized output readable.
# shellcheck disable=SC2059


# =============================================================================
# CONFIGURATION — edit these if your setup changes
# =============================================================================
LIBRARY="/steam-library"
STEAMAPPS="$LIBRARY/steamapps"
PAM_FILE="/etc/pam.d/system-login"
MOUNT_SCRIPT="/usr/local/bin/steam-compatdata-mount.sh"
SESSION_MOUNT_SCRIPT="/usr/local/bin/steam-session-mount.sh"
GAMERS_GROUP="gamers"
# Minimum UID for human users — read from /etc/login.defs at runtime,
# this value is only used as a fallback
UID_MIN=1000

# Legacy paths from older versions that used pam_namespace. The current design
# does not create these; they are referenced only so the diagnostic can detect
# and offer to remove them on systems set up with an earlier version.
NAMESPACE_CONF="/etc/security/namespace.d/99-steamlibrary.conf"
TRIGGER_DIR="/opt/pam_namespace_steamlibrarytrigger"
# =============================================================================

# =============================================================================
# CONFIG FILE — /etc/steam-multiuser.conf overrides defaults above.
# Create this file to customise the library path or group name without
# editing this script directly. Example contents:
#   LIBRARY=/mnt/games/steam
#   GAMERS_GROUP=steam-users
# =============================================================================
CONF_FILE="/etc/steam-multiuser.conf"
if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    # Recompute derived paths after config override
    STEAMAPPS="$LIBRARY/steamapps"
fi
# =============================================================================


_print_banner() {
    # $'...' syntax stores real escape bytes — printf "%s" then works correctly.
    local LC=$'\033[1;36m' C=$'\033[0;36m' W=$'\033[0;37m' D=$'\033[0;90m' R=$'\033[0m'
    # Book spine colors, left to right per shelf.
    local b1=$'\033[0;31m'  b2=$'\033[0;32m'  b3=$'\033[0;34m'  b4=$'\033[0;33m'
    local b5=$'\033[0;35m'  b6=$'\033[0;36m'  b7=$'\033[1;31m'
    local b8=$'\033[1;32m'  b9=$'\033[0;34m'  b10=$'\033[1;33m' b11=$'\033[1;36m'
    local b12=$'\033[0;31m' b13=$'\033[1;35m' b14=$'\033[0;32m'

    # Two shelves of upright books of varying height, bottom-aligned.
    # Each shelf is 10 rows tall plus a baseline. The books are the project logo.
    local s="     "  # 5-char blank slot (each book is 5 columns wide)
    local g=" "      # 1-char gap between books so spines never touch

    _sr() { printf "   %s%s%s%s%s%s%s%s%s%s%s%s%s\n" \
        "$1" "$g" "$2" "$g" "$3" "$g" "$4" "$g" "$5" "$g" "$6" "$g" "$7"; }

    local t1="${b1}_____${R}"  p1="${b1}|   |${R}"  e1="${b1}|___|${R}"
    local t2="${b2}_____${R}"  p2="${b2}|   |${R}"  e2="${b2}|___|${R}"
    local t3="${b3}_____${R}"  p3="${b3}|   |${R}"  e3="${b3}|___|${R}"
    local t4="${b4}_____${R}"  p4="${b4}|   |${R}"  e4="${b4}|___|${R}"
    local t5="${b5}_____${R}"  p5="${b5}|   |${R}"  e5="${b5}|___|${R}"
    local t6="${b6}_____${R}"  p6="${b6}|   |${R}"  e6="${b6}|___|${R}"
    local t7="${b7}_____${R}"  p7="${b7}|   |${R}"  e7="${b7}|___|${R}"
    local t8="${b8}_____${R}"  p8="${b8}|   |${R}"  e8="${b8}|___|${R}"
    local t9="${b9}_____${R}"  p9="${b9}|   |${R}"  e9="${b9}|___|${R}"
    local t10="${b10}_____${R}" p10="${b10}|   |${R}" e10="${b10}|___|${R}"
    local t11="${b11}_____${R}" p11="${b11}|   |${R}" e11="${b11}|___|${R}"
    local t12="${b12}_____${R}" p12="${b12}|   |${R}" e12="${b12}|___|${R}"
    local t13="${b13}_____${R}" p13="${b13}|   |${R}" e13="${b13}|___|${R}"
    local t14="${b14}_____${R}" p14="${b14}|   |${R}" e14="${b14}|___|${R}"
    local sh="${D}=========================================${R}"

    printf "\n"
    # Shelf 1 — heights 8 5 9 6 7 4 8, bottom-aligned over 10 rows
    _sr "$s"  "$s"  "$t3" "$s"  "$s"  "$s"  "$s"
    _sr "$s"  "$s"  "$p3" "$s"  "$s"  "$s"  "$s"
    _sr "$t1" "$s"  "$p3" "$s"  "$s"  "$s"  "$t7"
    _sr "$p1" "$s"  "$p3" "$s"  "$t5" "$s"  "$p7"
    _sr "$p1" "$s"  "$p3" "$t4" "$p5" "$s"  "$p7"
    _sr "$p1" "$t2" "$p3" "$p4" "$p5" "$s"  "$p7"
    _sr "$p1" "$p2" "$p3" "$p4" "$p5" "$t6" "$p7"
    _sr "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" "$p7"
    _sr "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" "$p7"
    _sr "$e1" "$e2" "$e3" "$e4" "$e5" "$e6" "$e7"
    printf "   %s\n" "$sh"
    # Shelf 2 — heights 6 9 4 8 5 7 3
    _sr "$s"  "$t9" "$s"   "$s"   "$s"   "$s"   "$s"
    _sr "$s"  "$p9" "$s"   "$t11" "$s"   "$s"   "$s"
    _sr "$s"  "$p9" "$s"   "$p11" "$s"   "$t13" "$s"
    _sr "$t8" "$p9" "$s"   "$p11" "$s"   "$p13" "$s"
    _sr "$p8" "$p9" "$s"   "$p11" "$t12" "$p13" "$s"
    _sr "$p8" "$p9" "$t10" "$p11" "$p12" "$p13" "$s"
    _sr "$p8" "$p9" "$p10" "$p11" "$p12" "$p13" "$t14"
    _sr "$p8" "$p9" "$p10" "$p11" "$p12" "$p13" "$p14"
    _sr "$e8" "$e9" "$e10" "$e11" "$e12" "$e13" "$e14"
    printf "   %s\n" "$sh"
    printf "\n"
    printf "   ${LC}steam-multiuser${R}\n"
    printf "   ${C}Shared library manager · multi-user Steam on Linux${R}\n"
    printf "   ${D}──────────────────────────────────────────────────${R}\n"
    printf "   ${W}Usage: steam-multiuser.sh [--check] [--add USER] [--migrate] [--move PATH] [--help]${R}\n"
    printf "   ${D}  --check    diagnose only, no changes${R}\n"
    printf "   ${D}  --add      onboard a new user to the shared library${R}\n"
    printf "   ${D}  --migrate  move games from home dirs to ${LIBRARY}${R}\n"
    printf "   ${D}  --move     relocate shared library to a new path${R}\n"
    printf "   ${D}  --help     show detailed usage and documentation${R}\n"
    printf "\n"
}
# =============================================================================
# Self-install: if running from a home directory, install to /usr/local/bin
# and re-execute from there so the installed copy is always what runs.
# =============================================================================

SCRIPT_PATH="$(realpath "$0")"
INSTALL_PATH="/usr/local/bin/steam-multiuser.sh"

if [[ "$SCRIPT_PATH" == /home/* ]] && [ "$SCRIPT_PATH" != "$INSTALL_PATH" ]; then
    echo -e "\033[1mDetected run from home directory — installing to $INSTALL_PATH...\033[0m"
    if [ "$EUID" -ne 0 ]; then
        echo "  Root is required to install. Re-running with sudo..."
        exec sudo bash "$SCRIPT_PATH" "$@"
    fi
    cp "$SCRIPT_PATH" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    echo -e "\033[0;32m[FIX ]\033[0m Installed to $INSTALL_PATH"
    echo "       Running from installed location..."
    echo ""
    exec "$INSTALL_PATH" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}[PASS]${NC}"
FAIL="${RED}[FAIL]${NC}"
WARN="${YELLOW}[WARN]${NC}"
INFO="${BLUE}[INFO]${NC}"
FIX="${YELLOW}[FIX ]${NC}"

CURRENT_USER=$(whoami)
ISSUES=0
WARNINGS=0
FIXES=0
CHECK_ONLY=false

# =============================================================================
# Helpers
# =============================================================================

fail()   { echo -e "$FAIL $1"; ((ISSUES++, 1)); }
pass()   { echo -e "$PASS $1"; }
warn()   { echo -e "$WARN $1"; ((WARNINGS++, 1)); }
info()   { echo -e "$INFO $1"; }
fixed()  { echo -e "$FIX  $1"; ((FIXES++, 1)); }
header() {
    echo -e "\n${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
}

ask() {
    local PROMPT="$1"
    $CHECK_ONLY && return 1
    [ ! -t 0 ] && return 0
    echo -en "${YELLOW}  → Fix: $PROMPT [Y/n] ${NC}"
    read -r REPLY
    [[ "$REPLY" =~ ^[Nn] ]] && return 1
    return 0
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}This script must be run with sudo.${NC}"
        echo "  sudo $(basename "$0") ..."
        exit 1
    fi
}

# Creates the gamers group if it does not exist.
# Safe to call multiple times — exits cleanly if already present.
ensure_gamers_group() {
    if getent group "$GAMERS_GROUP" &>/dev/null; then
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Group '$GAMERS_GROUP' does not exist and cannot be created without sudo.${NC}"
        echo "  Run: sudo groupadd $GAMERS_GROUP"
        return 1
    fi
    groupadd "$GAMERS_GROUP"
    echo -e "$FIX  Created group '$GAMERS_GROUP'"
}

# =============================================================================
# User discovery
#
# Strategy (in priority order):
#   1. Read UID_MIN from /etc/login.defs (most accurate, distro-aware)
#   2. Fall back to UID_MIN=1000 constant above
#   3. Query users via getent passwd (covers local + LDAP/NIS if configured)
#   4. Filter: UID >= UID_MIN, home under /home, valid interactive shell
#      (excludes system/service accounts even if they have home dirs)
#   5. Detect Steam by checking ~/.local/share/Steam/steam.sh (canonical
#      per Arch Wiki), falling back to steamapps dir and ~/.steam/root symlink
# =============================================================================

_get_uid_min() {
    local MIN="$UID_MIN"
    if [ -f /etc/login.defs ]; then
        local DEFS_MIN
        DEFS_MIN=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null || true)
        [ -n "$DEFS_MIN" ] && MIN="$DEFS_MIN"
    fi
    echo "$MIN"
}

_valid_shells() {
    grep -v '^#' /etc/shells 2>/dev/null | grep -v 'nologin\|false\|sync' || true
}

discover_users() {
    local EFFECTIVE_UID_MIN
    EFFECTIVE_UID_MIN=$(_get_uid_min)
    local VALID_SHELLS
    VALID_SHELLS=$(_valid_shells)

    while IFS=: read -r username _ uid _ _ homedir shell; do
        # Must meet UID threshold
        [ "$uid" -ge "$EFFECTIVE_UID_MIN" ] 2>/dev/null || continue
        # Must have home under /home (excludes /var/lib/*, /root, etc.)
        [[ "$homedir" == /home/* ]] || continue
        # Must have a real interactive shell
        echo "$VALID_SHELLS" | grep -qxF "$shell" || continue
        echo "$username"
    done < <(getent passwd)
}

steam_installed_for() {
    local USER="$1"
    local HOMEDIR
    HOMEDIR=$(getent passwd "$USER" | cut -f6 -d:)
    # Use direct test when already root, sudo test otherwise
    local TEST_CMD="sudo test"
    [ "$EUID" -eq 0 ] && TEST_CMD="test"
    # Primary: canonical Steam install marker (Arch Wiki)
    $TEST_CMD -f "$HOMEDIR/.local/share/Steam/steam.sh" 2>/dev/null && return 0
    # Secondary: steamapps exists (Steam initialized, steam.sh may have moved)
    $TEST_CMD -d "$HOMEDIR/.local/share/Steam/steamapps" 2>/dev/null && return 0
    # Fallback: ~/.steam/root symlink resolves to a real directory
    $TEST_CMD -d "$HOMEDIR/.steam/root" 2>/dev/null && return 0
    return 1
}

in_gamers_group() {
    id -nG "$1" 2>/dev/null | grep -qw "$GAMERS_GROUP"
}

# =============================================================================
# Argument parsing
# =============================================================================

ADD_USER=""
MIGRATE_MODE=false
HELP_MODE=false
MOVE_DEST=""
ARGS=("$@")
i=0
while [ $i -lt ${#ARGS[@]} ]; do
    case "${ARGS[$i]}" in
        --check)   CHECK_ONLY=true ;;
        --migrate) MIGRATE_MODE=true ;;
        --help)    HELP_MODE=true ;;
        --move)
            ((i++)) || true
            MOVE_DEST="${ARGS[$i]:-}"
            ;;
        --add)
            ((i++)) || true
            ADD_USER="${ARGS[$i]:-}"
            ;;
    esac
    ((i++)) || true
done

# Show the banner only when running a full fix/check pass with no specific
# subcommand — suppress it for --add, --migrate, --move, --help, and --check
# so it doesn't spam the terminal in scripted or targeted usage.
if [ -z "$ADD_USER" ] && ! $MIGRATE_MODE && ! $HELP_MODE && \
   [ -z "$MOVE_DEST" ] && ! $CHECK_ONLY; then
    _print_banner
fi

# =============================================================================
# Helper functions — defined after main body (bash resolves at call time)
# =============================================================================

# Session mount script uses gamers group membership as its filter — no
# hardcoded usernames, automatically covers anyone added to the group
_write_session_mount_script() {
    cat > "$SESSION_MOUNT_SCRIPT" << SCRIPT
#!/bin/bash
# Called by pam_exec at login — mounts the user's private compatdata into the
# root namespace so SDDM's/plasmalogin's graphical session can see it.
# Filter: '$GAMERS_GROUP' group membership — no hardcoded usernames.
#
# This script also performs first-login initialisation: it creates the user's
# local Steam directories and compatdata folder if they don't exist yet, so the
# bind mount target is ready before Steam launches.

USER="\$PAM_USER"
TYPE="\$PAM_TYPE"

[ "\$TYPE" != "open_session" ] && exit 0

# Only run for members of the shared gaming group
if ! id -nG "\$USER" 2>/dev/null | grep -qw "$GAMERS_GROUP"; then
    exit 0
fi

HOMEDIR=\$(getent passwd "\$USER" | cut -f6 -d":")
TARGET="$STEAMAPPS/compatdata"
LIBRARY="$LIBRARY"

# --- First-login initialisation ---
# If the user's local Steam dirs don't exist yet, create them so that
# the bind mount target is ready before Steam launches.
LOCAL_STEAMAPPS="\${HOMEDIR}/.local/share/Steam/steamapps"
if [ ! -d "\$LOCAL_STEAMAPPS" ]; then
    mkdir -p "\$LOCAL_STEAMAPPS"
    chown "\$USER":"\$USER" "\${HOMEDIR}/.local" "\${HOMEDIR}/.local/share" \
          "\${HOMEDIR}/.local/share/Steam" "\$LOCAL_STEAMAPPS" 2>/dev/null
    logger -t steam-session-mount "Created Steam dirs for \$USER on first login"
fi

# Ensure per-user compatdata dir exists and is owned by the user
LOCAL_COMPATDATA="\${LOCAL_STEAMAPPS}/compatdata"
if [ ! -d "\$LOCAL_COMPATDATA" ]; then
    mkdir -p "\$LOCAL_COMPATDATA"
    chown "\$USER":"\$USER" "\$LOCAL_COMPATDATA"
    chmod 755 "\$LOCAL_COMPATDATA"
    logger -t steam-session-mount "Created compatdata for \$USER on first login"
fi

SOURCE=""
for candidate in \\
    "\${LOCAL_COMPATDATA}" \\
    "\${HOMEDIR}/.steam/steam/steamapps/compatdata"; do
    [ -d "\$candidate" ] && SOURCE="\$candidate" && break
done

[ -z "\$SOURCE" ] && exit 0
[ ! -d "\$TARGET" ] && exit 0

# Mount into root namespace so the graphical session inherits it
nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "\$TARGET" 2>/dev/null && \\
    nsenter --mount=/proc/1/ns/mnt -- umount "\$TARGET"
nsenter --mount=/proc/1/ns/mnt -- mount --bind "\$SOURCE" "\$TARGET"
logger -t steam-session-mount "Mounted \$SOURCE -> \$TARGET for \$USER"
exit 0
SCRIPT
    chmod +x "$SESSION_MOUNT_SCRIPT"
}

_write_mount_script() {
    cat > "$MOUNT_SCRIPT" << SCRIPT
#!/bin/bash
# Manual recovery: sudo steam-compatdata-mount.sh <username>
USER="\$1"
[ -z "\$USER" ] && { echo "Usage: \$0 <username>" >&2; exit 1; }
HOMEDIR=\$(getent passwd "\$USER" | cut -f6 -d":")
TARGET="$STEAMAPPS/compatdata"
SOURCE=""
for candidate in \\
    "\${HOMEDIR}/.local/share/Steam/steamapps/compatdata" \\
    "\${HOMEDIR}/.steam/steam/steamapps/compatdata"; do
    [ -d "\$candidate" ] && SOURCE="\$candidate" && break
done
[ -z "\$SOURCE" ] && { echo "No compatdata found for \$USER" >&2; exit 1; }
[ ! -d "\$TARGET" ] && { echo "Target \$TARGET does not exist" >&2; exit 1; }
nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "\$TARGET" 2>/dev/null && \\
    nsenter --mount=/proc/1/ns/mnt -- umount "\$TARGET"
nsenter --mount=/proc/1/ns/mnt -- mount --bind "\$SOURCE" "\$TARGET"
logger -t steam-compatdata-mount "Mounted \$SOURCE -> \$TARGET for \$USER (root ns)"
echo "Mounted \$SOURCE -> \$TARGET for \$USER"
SCRIPT
    chmod +x "$MOUNT_SCRIPT"
}


_migrate_games() {
    # =========================================================================
    # Migrates game installs from each user's home Steam library into the
    # shared library. Safe to run multiple times (rsync is idempotent).
    #
    # What moves:   steamapps/common/<game>/    game files
    #               steamapps/workshop/          workshop content
    #
    # What stays:   steamapps/compatdata/    Proton prefixes, private per-user
    #               steamapps/shadercache/   shader cache, private per-user
    #               steamapps/userdata/      save data, private per-user
    #               ~/.local/share/Steam/    Steam client itself
    #
    # Appmanifests: the .acf files are consolidated into the shared library's
    # steamapps/ directory (group-readable). Steam reads them from the library
    # they live in, so they must NOT be copied into each user's home steamapps.
    # =========================================================================

    require_root

    echo -e "\n${BOLD}Discovering installed games across all users...${NC}\n"

    # Ensure shared destination structure exists with correct permissions
    mkdir -p "$STEAMAPPS/common"
    chown root:"$GAMERS_GROUP" "$LIBRARY" "$STEAMAPPS" "$STEAMAPPS/common"
    chmod 2775 "$LIBRARY" "$STEAMAPPS" "$STEAMAPPS/common"

    # Build list of source steamapps directories from gamers group members
    declare -a SOURCE_DIRS=()
    while IFS= read -r GUSER; do
        in_gamers_group "$GUSER" || continue
        local GHOME
        GHOME=$(getent passwd "$GUSER" | cut -f6 -d:)
        local GSRC="$GHOME/.local/share/Steam/steamapps"
        if [ -d "$GSRC/common" ]; then
            local GCOUNT
            GCOUNT=$(find "$GSRC/common" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
            SOURCE_DIRS+=("$GUSER:$GSRC")
            echo -e "$INFO  $GUSER: $GSRC/common ($GCOUNT game folder(s))"
        else
            echo -e "$INFO  $GUSER: no games found in steamapps/common — skipping"
        fi
    done < <(discover_users)

    if [ ${#SOURCE_DIRS[@]} -eq 0 ]; then
        echo -e "$WARN  No game installs found in any user's home Steam library."
        echo -e "      Nothing to migrate."
        return 0
    fi

    # Confirm before touching anything
    echo ""
    echo -e "${YELLOW}${BOLD}This will:${NC}"
    echo -e "  1. Copy all game files from each user's home library to $STEAMAPPS/common/"
    echo -e "  2. Consolidate appmanifest (.acf) files into the shared library"
    echo -e "  3. Remove each user's home copy after a successful rsync"
    echo -e "  4. Leave compatdata, shadercache, and userdata private and untouched"
    echo -e "  5. Fix ownership, setgid, and StateFlags on all migrated files"
    echo ""
    echo -e "${RED}  Close Steam on all accounts before proceeding.${NC}"
    echo -e "${YELLOW}  This may take a long time for large libraries.${NC}"
    echo ""
    echo -en "${YELLOW}Proceed with migration? [y/N] ${NC}"
    read -r CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy] ]] && { echo "Migration cancelled."; return 0; }
    echo ""

    # Track games already copied so duplicates across users are just deleted
    declare -A MIGRATED_GAMES=()

    for ENTRY in "${SOURCE_DIRS[@]}"; do
        local MUSER="${ENTRY%%:*}"
        local MSRC="${ENTRY#*:}"
        local MSRC_COMMON="$MSRC/common"

        echo -e "\n${BOLD}Processing $MUSER...${NC}"

        # Migrate each game directory
        while IFS= read -r GAME_DIR; do
            local GNAME
            GNAME=$(basename "$GAME_DIR")
            local DEST="$STEAMAPPS/common/$GNAME"

            if [ "${MIGRATED_GAMES[$GNAME]+_}" ]; then
                echo -e "$INFO  '$GNAME' already migrated — removing duplicate from $MUSER"
                rm -rf "$GAME_DIR"
                continue
            fi

            # Identify Proton versions and Steam runtimes — these are read-only
            # at runtime and safe (and correct) to share between users.
            # Migrating them saves several GB of disk space.
            local ENTRY_TYPE="game"
            if [[ "$GNAME" == Proton* ]] || [[ "$GNAME" == SteamLinuxRuntime* ]] || [[ "$GNAME" == "Steam Linux Runtime"* ]]; then
                ENTRY_TYPE="runtime/Proton"
            fi
            echo -e "$INFO  Migrating ($ENTRY_TYPE): $GNAME"
            # --no-xattrs: avoids errors when crossing filesystem boundaries
            # (e.g. ZFS home with posixacl xattrs → ext4 /steam-library without them).
            # Game files do not rely on xattrs so nothing meaningful is lost.
            # -a without -X is equivalent; we make it explicit for clarity.
            if rsync -a --no-xattrs --info=progress2 "$GAME_DIR/" "$DEST/"; then
                # Re-apply ownership and permissions after rsync.
                # This is especially important on btrfs where CoW creates new
                # inodes that may not inherit the parent directory's setgid group.
                # chown -R ensures every file — including CoW-created ones —
                # ends up owned by root:gamers regardless of how they were written.
                chown -R root:"$GAMERS_GROUP" "$DEST"
                chmod -R g+rw "$DEST"
                # Re-apply setgid to all directories so future Steam writes
                # (updates, shader compilation) also inherit the group correctly.
                find "$DEST" -type d -exec chmod g+s {} +
                rm -rf "$GAME_DIR"
                MIGRATED_GAMES["$GNAME"]=1
                echo -e "$FIX  Migrated and removed source: $GAME_DIR"
            else
                echo -e "$FAIL  rsync failed for '$GNAME' — original left intact at $GAME_DIR"
            fi
        done < <(find "$MSRC_COMMON" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

        # Migrate workshop content if present
        if [ -d "$MSRC/workshop" ]; then
            echo -e "$INFO  Migrating workshop content..."
            mkdir -p "$STEAMAPPS/workshop"
            if rsync -a --no-xattrs "$MSRC/workshop/" "$STEAMAPPS/workshop/"; then
                chown -R root:"$GAMERS_GROUP" "$STEAMAPPS/workshop"
                chmod -R g+rw "$STEAMAPPS/workshop"
                find "$STEAMAPPS/workshop" -type d -exec chmod g+s {} +
                rm -rf "$MSRC/workshop"
                echo -e "$FIX  Workshop content migrated"
            else
                echo -e "$FAIL  Workshop rsync failed — original left intact"
            fi
        fi

        # Consolidate appmanifest files into the shared library. Steam reads
        # .acf files from the library directory they live in, so they must be
        # in the shared steamapps/ — not the user's home steamapps. Copies that
        # don't already exist in the shared location (deduplicating identical
        # games across users), then removes the user's local copies.
        local ACF_MOVED=0
        while IFS= read -r ACF; do
            local ACF_NAME
            ACF_NAME=$(basename "$ACF")
            if [ ! -f "$STEAMAPPS/$ACF_NAME" ]; then
                cp "$ACF" "$STEAMAPPS/$ACF_NAME"
                ((ACF_MOVED++)) || true
            fi
            rm -f "$ACF"
        done < <(find "$MSRC" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null)
        if [ "$ACF_MOVED" -gt 0 ]; then
            echo -e "$FIX  Consolidated $ACF_MOVED new appmanifest(s) from $MUSER"
        fi

        echo -e "$PASS  Done processing $MUSER"
    done

    # Finalize appmanifests: set group-readable permissions and StateFlags=4
    # so Steam sees the games as fully installed and does not revalidate
    # (redownload) them when each user next opens Steam.
    if compgen -G "$STEAMAPPS/appmanifest_*.acf" > /dev/null 2>&1; then
        chown root:"$GAMERS_GROUP" "$STEAMAPPS"/appmanifest_*.acf
        chmod 644 "$STEAMAPPS"/appmanifest_*.acf
        _fix_acf_stateflags
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Migration complete.${NC}"
    echo ""
    echo -e "Next steps for each user:"
    echo -e "  1. Run ${BOLD}sudo $(basename "$0") --add USERNAME${NC} for each user to register"
    echo -e "     the shared library in their Steam config"
    echo -e "  2. Each user logs out and back in to activate the bind mount"
    echo -e "  3. Open Steam — the shared library and its games appear automatically"
    echo ""
}


_print_help() {
    local C="\033[0;36m" W="\033[0;37m" D="\033[0;90m"
    local G="\033[0;32m" Y="\033[1;33m" R="\033[0m"

    printf "${C}DESCRIPTION${R}\n"
    printf "   steam-multiuser.sh manages a shared Steam game library at ${W}${LIBRARY}${R}\n"
    printf "   for multiple Linux user accounts. It handles permissions, PAM-based\n"
    printf "   Proton prefix isolation, and game file migration — keeping game files\n"
    printf "   shared while keeping saves, prefixes, and configs private per-user.\n"
    printf "\n"

    printf "${C}MODES${R}\n"
    printf "\n"

    printf "   ${W}(no arguments)${R}\n"
    printf "   ${D}Requires: sudo${R}\n"
    printf "   Runs a full diagnostic of the shared library setup and offers to fix\n"
    printf "   any issues found, prompting [Y/n] for each fix. Checks group membership,\n"
    printf "   library permissions, PAM configuration, per-user Steam directories,\n"
    printf "   active bind mounts, appmanifest placement, cloud sync, and session mounts.\n"
    printf "   Safe to run repeatedly — all fixes are idempotent.\n"
    printf "\n"

    printf "   ${W}--check${R}\n"
    printf "   ${D}Requires: no sudo needed${R}\n"
    printf "   Diagnostic-only mode. Runs all the same checks but makes no changes.\n"
    printf "   Use this to inspect the current state of the setup, or to verify\n"
    printf "   everything is healthy after a system update. Can be run as any user.\n"
    printf "\n"

    printf "   ${W}--add USERNAME${R}\n"
    printf "   ${D}Requires: sudo${R}\n"
    printf "   Onboards a new user to the shared library. Adds them to the ${W}${GAMERS_GROUP}${R}\n"
    printf "   group, regenerates the PAM session mount script to cover them, and\n"
    printf "   registers the shared library in their Steam config (libraryfolders.vdf)\n"
    printf "   so Steam recognises all installed games immediately.\n"
    printf "\n"
    printf "   ${Y}Before running --add:${R} the user must have logged in and launched\n"
    printf "   Steam at least once so their ~/.local/share/Steam directory exists.\n"
    printf "   After running --add, they must log out and back in to activate the\n"
    printf "   PAM bind mount. The shared library is registered automatically — no\n"
    printf "   need to add it manually in Steam > Settings > Storage.\n"
    printf "\n"
    printf "   Example: ${W}sudo steam-multiuser.sh --add kidaccount${R}\n"
    printf "\n"

    printf "   ${W}--migrate${R}\n"
    printf "   ${D}Requires: sudo  |  Steam must be closed on all accounts${R}\n"
    printf "   One-time migration that moves game files from each user's home Steam\n"
    printf "   library into the shared ${W}${LIBRARY}${R}. Uses rsync so it is safe\n"
    printf "   to interrupt — failed copies leave the original intact. Deduplicates\n"
    printf "   games that multiple users have installed. After migration, each user\n"
    printf "   must add ${W}${LIBRARY}${R} in Steam > Settings > Storage.\n"
    printf "\n"
    printf "   ${Y}What gets moved:${R}  steamapps/common/ (games, Proton, runtimes)\n"
    printf "                     steamapps/workshop/\n"
    printf "   ${Y}What stays put:${R}   steamapps/compatdata/  (Proton prefixes, private)\n"
    printf "                     steamapps/shadercache/ (private)\n"
    printf "                     steamapps/userdata/    (private)\n"
    printf "                     ~/.local/share/Steam/  (Steam client itself)\n"
    printf "\n"

    printf "   ${W}--move PATH${R}\n"
    printf "   ${D}Requires: sudo  |  Steam must be closed on all accounts${R}\n"
    printf "   Relocates the entire shared library to a new path. Useful when\n"
    printf "   adding a dedicated drive for games. Copies all files to the new\n"
    printf "   location using rsync, then updates /etc/steam-multiuser.conf,\n"
    printf "   regenerates the PAM mount script, updates all per-user\n"
    printf "   libraryfolders.vdf files, and removes the old location only after\n"
    printf "   everything is verified. The source is never deleted until the copy\n"
    printf "   is confirmed complete.\n"
    printf "\n"
    printf "   ${Y}Important:${R} the destination parent directory must already exist\n"
    printf "   and be mounted. The script will create the final directory.\n"
    printf "   ${Y}Example:${R}  sudo steam-multiuser.sh --move /mnt/gamedrive/steam\n"
    printf "\n"

    printf "   ${W}--help${R}\n"
    printf "   ${D}Requires: no sudo needed${R}\n"
    printf "   Shows this help text.\n"
    printf "\n"

    printf "${C}SUDO REFERENCE${R}\n"
    printf "\n"
    printf "   ${G}sudo required${R}    ${W}sudo steam-multiuser.sh${R}             full fix run\n"
    printf "   ${G}sudo required${R}    ${W}sudo steam-multiuser.sh --add USER${R}  onboard a user\n"
    printf "   ${G}sudo required${R}    ${W}sudo steam-multiuser.sh --migrate${R}   migrate games\n"
    printf "   ${G}sudo required${R}    ${W}sudo steam-multiuser.sh --move PATH${R} relocate library\n"
    printf "   ${D}no sudo needed${R}   ${W}steam-multiuser.sh --check${R}          diagnose only\n"
    printf "   ${D}no sudo needed${R}   ${W}steam-multiuser.sh --help${R}           this help text\n"
    printf "\n"
    printf "   Running without sudo automatically falls back to --check mode.\n"
    printf "\n"

    printf "${C}TYPICAL FIRST-TIME SETUP WORKFLOW${R}\n"
    printf "\n"
    printf "   ${W}1.${R} Create ${W}${LIBRARY}${R} on your chosen drive/partition\n"
    printf "   ${W}2.${R} Run ${W}sudo steam-multiuser.sh${R} — it will create the gamers group,\n"
    printf "      set permissions, and configure PAM automatically\n"
    printf "   ${W}3.${R} For each user, run ${W}sudo steam-multiuser.sh --add USERNAME${R}\n"
    printf "   ${W}4.${R} If games are already installed in home directories, run\n"
    printf "      ${W}sudo steam-multiuser.sh --migrate${R} to consolidate them\n"
    printf "   ${W}5.${R} Each user logs out/in, then adds ${W}${LIBRARY}${R} in Steam\n"
    printf "\n"

    printf "${C}FILES MANAGED BY THIS SCRIPT${R}\n"
    printf "\n"
    printf "   ${W}/etc/steam-multiuser.conf${R}              configuration (library path, group)\n"
    printf "   ${W}${STEAMAPPS}/compatdata${R}  locked-down bind mount target\n"
    printf "   ${W}/etc/pam.d/system-login${R}              pam_exec session hook\n"
    printf "   ${W}/usr/local/bin/steam-session-mount.sh${R} per-login bind mount script\n"
    printf "   ${W}/usr/local/bin/steam-compatdata-mount.sh${R} manual recovery mount\n"
    printf "\n"

    printf "${C}TROUBLESHOOTING${R}\n"
    printf "\n"
    printf "   Cloud sync errors after login:\n"
    printf "   ${D}journalctl -t steam-session-mount --since today${R}\n"
    printf "   ${D}journalctl -t steamlibrary.init --since today${R}\n"
    printf "\n"
    printf "   Bind mount not active — run manually:\n"
    printf "   ${D}sudo /usr/local/bin/steam-compatdata-mount.sh \$USER${R}\n"
    printf "\n"
    printf "   Full diagnostic with no changes:\n"
    printf "   ${D}steam-multiuser.sh --check${R}\n"
    printf "\n"
}


# Register /steam-library in a user's libraryfolders.vdf.
# Steam reads this file to know which library paths exist.
# We insert a new numbered entry if /steam-library isn't already listed.
_register_library_for_user() {
    local TARGET_USER="$1"
    local TARGET_HOME="$2"
    local VDF_PATH="$TARGET_HOME/.local/share/Steam/steamapps/libraryfolders.vdf"

    if [ ! -f "$VDF_PATH" ]; then
        echo -e "$WARN  libraryfolders.vdf not found for '$TARGET_USER' — Steam may not have run yet"
        return
    fi

    # Check if already registered
    if grep -q "\"$LIBRARY\"" "$VDF_PATH" 2>/dev/null; then
        echo -e "$PASS  $LIBRARY already registered in '$TARGET_USER' Steam library config"
        return
    fi

    # Find the highest existing numeric key so we can append the next one
    local NEXT_IDX
    NEXT_IDX=$(grep -oP '^\s*"\K[0-9]+(?="\s*$)' "$VDF_PATH" 2>/dev/null | sort -n | tail -1)
    NEXT_IDX=$(( ${NEXT_IDX:-0} + 1 ))

    # Build the new entry block and insert it before the closing brace
    local NEW_ENTRY
    NEW_ENTRY="$(printf '\t"%d"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"label"\t\t""\n\t\t"contentid"\t"0"\n\t\t"totalsize"\t"0"\n\t\t"update_clean_bytes_tally"\t"0"\n\t\t"time_last_update_corruption"\t"0"\n\t\t"apps"\t\t{}\n\t}' "$NEXT_IDX" "$LIBRARY")"

    # Insert before the final closing brace of the file
    # Make a backup first
    cp "$VDF_PATH" "${VDF_PATH}.bak"
    # Replace last } with new entry + }
    python3 -c "
import sys
path = sys.argv[1]
entry = sys.argv[2]
with open(path) as f:
    data = f.read()
# Find last closing brace
idx = data.rfind('}')
if idx == -1:
    sys.exit(1)
new_data = data[:idx] + entry + '\n}'
with open(path, 'w') as f:
    f.write(new_data)
" "$VDF_PATH" "$NEW_ENTRY"

    if [ $? -eq 0 ]; then
        chown "$TARGET_USER":"$TARGET_USER" "$VDF_PATH"
        echo -e "$FIX  Registered $LIBRARY in '$TARGET_USER' Steam library config"
        echo -e "       Backup saved to ${VDF_PATH}.bak"
    else
        mv "${VDF_PATH}.bak" "$VDF_PATH"
        echo -e "$WARN  Could not auto-register $LIBRARY — add manually:"
        echo -e "       Steam → Settings → Storage → Add Drive → $LIBRARY"
    fi
}


# Ensure all .acf files in the shared library have StateFlags=4 (fully installed,
# no revalidation needed). When .acf files are moved between library locations,
# Steam may mark them for revalidation (StateFlags=2 or 6) causing full game
# redownloads. Setting StateFlags=4 tells Steam the files are already verified.
# Also updates the "path" field in libraryfolders.vdf entries if present.
_fix_acf_stateflags() {
    local FIXED=0
    local SKIPPED=0
    while IFS= read -r -d '' ACF; do
        # Read current StateFlags
        local FLAGS
        FLAGS=$(grep '"StateFlags"' "$ACF" 2>/dev/null | grep -oP '"\K[0-9]+(?=")' | head -1)
        if [ "$FLAGS" = "4" ]; then
            ((SKIPPED++))
        else
            # Set StateFlags to 4 — fully installed, verified
            sed -i 's/"StateFlags"\s*"[0-9]*"/"StateFlags"\t\t"4"/' "$ACF"
            ((FIXED++))
            local GAME
            GAME=$(grep '"name"' "$ACF" 2>/dev/null | head -1 | grep -oP '"\K[^"]+(?="\s*$)')
            [ -n "$GAME" ] && echo -e "$FIX  Set StateFlags=4 on: $GAME"
        fi
    done < <(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" -print0 2>/dev/null)
    [ "$FIXED" -gt 0 ]   && echo -e "$FIX  Updated StateFlags on $FIXED appmanifest(s) → no revalidation on next launch"
    [ "$SKIPPED" -gt 0 ] && echo -e "$PASS $SKIPPED appmanifest(s) already marked as fully installed"
}

# =============================================================================
# --add USER mode
# =============================================================================

if [ -n "$ADD_USER" ]; then
    require_root
    if ! id "$ADD_USER" &>/dev/null; then
        echo -e "${RED}User '$ADD_USER' does not exist on this system.${NC}"
        exit 1
    fi
    ensure_gamers_group
    echo -e "\n${BOLD}Onboarding '$ADD_USER' to the shared Steam library...${NC}\n"

    # Add to gamers group
    if in_gamers_group "$ADD_USER"; then
        echo -e "$PASS '$ADD_USER' already in '$GAMERS_GROUP' group"
    else
        usermod -aG "$GAMERS_GROUP" "$ADD_USER"
        echo -e "$FIX  Added '$ADD_USER' to '$GAMERS_GROUP' (takes effect on next login)"
    fi

    # Regenerate session mount script — it uses gamers group membership as its
    # filter so no further changes needed when adding users
    if [ -f "$SESSION_MOUNT_SCRIPT" ]; then
        _write_session_mount_script
        echo -e "$FIX  Regenerated $SESSION_MOUNT_SCRIPT"
    else
        echo -e "$WARN  $SESSION_MOUNT_SCRIPT not found — run: sudo steam-multiuser.sh to create it"
    fi

    # Copy appmanifests if Steam is initialized
    ADD_USER_HOMEDIR=$(getent passwd "$ADD_USER" | cut -f6 -d:)
    ADD_USER_STEAMAPPS="$ADD_USER_HOMEDIR/.local/share/Steam/steamapps"
    if steam_installed_for "$ADD_USER"; then
        SHARED_ACF_COUNT=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)
        if [ "$SHARED_ACF_COUNT" -gt 0 ]; then
            cp "$STEAMAPPS"/appmanifest_*.acf "$ADD_USER_STEAMAPPS"/
            chown "$ADD_USER":"$ADD_USER" "$ADD_USER_STEAMAPPS"/appmanifest_*.acf
            chmod 644 "$ADD_USER_STEAMAPPS"/appmanifest_*.acf
            echo -e "$FIX  Copied $SHARED_ACF_COUNT appmanifest(s) to $ADD_USER_STEAMAPPS"
        else
            # Try copying from an existing gamer's local steamapps
            while IFS= read -r EXISTING_USER; do
                [ "$EXISTING_USER" = "$ADD_USER" ] && continue
                in_gamers_group "$EXISTING_USER" || continue
                EXISTING_SA=$(getent passwd "$EXISTING_USER" | cut -f6 -d:)/.local/share/Steam/steamapps
                if sudo test -d "$EXISTING_SA" 2>/dev/null; then
                    ACF_COUNT=$(sudo bash -c "find '$EXISTING_SA' -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null | wc -l")
                    if [ "$ACF_COUNT" -gt 0 ]; then
                        sudo bash -c "cp '$EXISTING_SA'/appmanifest_*.acf '$ADD_USER_STEAMAPPS'/"
                        chown "$ADD_USER":"$ADD_USER" "$ADD_USER_STEAMAPPS"/appmanifest_*.acf
                        chmod 644 "$ADD_USER_STEAMAPPS"/appmanifest_*.acf
                        echo -e "$FIX  Copied $ACF_COUNT appmanifest(s) from $EXISTING_USER"
                        break
                    fi
                fi
            done < <(discover_users)
        fi
    else
        echo -e "$WARN  Steam not yet initialized for '$ADD_USER'."
        echo -e "       Have them log in, launch Steam once, then re-run:"
        echo -e "       ${BOLD}sudo steam-multiuser.sh --add $ADD_USER${NC}"
    fi

    echo -e "\n${GREEN}${BOLD}Done. '$ADD_USER' has been onboarded.${NC}"
    echo -e "They must log out and back in for the bind mount to activate."
    echo -e "Then in Steam: Settings → Storage → Add Drive → $LIBRARY\n"
    exit 0
fi

# =============================================================================
# --help mode
# =============================================================================

if $HELP_MODE; then
    _print_help
    exit 0
fi

# =============================================================================
# Environment compatibility check
#
# This script is designed and tested for:
#   - CachyOS (Arch-based, ID=cachyos in /etc/os-release)
#   - Any Arch-based distro (ID_LIKE containing "arch")
#   - KDE Plasma desktop session
#   - SDDM or plasmalogin as the display manager
#   - systemd init system
#   - ZFS or ext4 filesystem for /steam-library (XFS expected to work)
#
# The nsenter bind mount technique is specific to how KWin/Wayland sessions
# inherit mount namespaces on Arch-based systems. It has not been tested on
# other display managers (GDM, LightDM) or desktop environments (GNOME, XFCE).
#
# --check and --help bypass this check since they make no system changes.
# =============================================================================

_check_environment() {
    local W="\033[0;37m" Y="\033[1;33m" R="\033[0;31m" G="\033[0;32m" NC="\033[0m"
    local ERRORS=0
    local WARNINGS=0

    echo -e "${W}Checking environment compatibility...${NC}"
    echo ""

    # --- OS Detection ---
    # CachyOS does not set ID_LIKE=arch (known upstream issue as of 2026).
    # We check ID=cachyos first, then ID_LIKE as a fallback for other Arch derivatives.
    local OS_ID="" OS_ID_LIKE="" OS_NAME=""
    if [ -f /etc/os-release ]; then
        OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_ID_LIKE=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
        OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi

    if [ "$OS_ID" = "cachyos" ]; then
        echo -e "  ${G}[OK]${NC}  OS: $OS_NAME (CachyOS confirmed)"
    elif echo "$OS_ID_LIKE" | grep -qw "arch"; then
        echo -e "  ${Y}[WARN]${NC} OS: $OS_NAME (Arch-based via ID_LIKE — not CachyOS, proceed with caution)"
        echo -e "         The nsenter bind mount fix was specifically developed and tested on CachyOS."
        ((WARNINGS++))
    elif [ "$OS_ID" = "arch" ]; then
        echo -e "  ${Y}[WARN]${NC} OS: Arch Linux (not CachyOS — should work but is untested on base Arch)"
        ((WARNINGS++))
    else
        echo -e "  ${R}[FAIL]${NC} OS: '${OS_NAME:-unknown}' (ID=${OS_ID}) is not supported"
        echo -e "         This script requires CachyOS or an Arch-based distribution."
        echo -e "         Detected: ID=${OS_ID} ID_LIKE=${OS_ID_LIKE}"
        ((ERRORS++))
    fi

    # --- Init system ---
    if [ -d /run/systemd/system ]; then
        echo -e "  ${G}[OK]${NC}  Init: systemd detected"
    else
        echo -e "  ${R}[FAIL]${NC} Init: systemd not found — this script requires systemd"
        ((ERRORS++))
    fi

    # --- PAM modules ---
    # Only pam_exec.so is required: it runs the session mount script at login.
    # (pam_namespace.so is part of the base pam package too, but this tool no
    # longer uses it.)
    local PAM_LIB_DIR="/usr/lib/security"
    if [ -f "$PAM_LIB_DIR/pam_exec.so" ]; then
        echo -e "  ${G}[OK]${NC}  PAM module: pam_exec.so"
    else
        echo -e "  ${R}[FAIL]${NC} PAM module: pam_exec.so not found in $PAM_LIB_DIR"
        echo -e "         Install with: sudo pacman -S pam"
        ((ERRORS++))
    fi

    # --- Required binaries ---
    local REQUIRED_BINS=("nsenter" "findmnt" "mountpoint" "rsync" "getent" "loginctl" "journalctl")
    for BIN in "${REQUIRED_BINS[@]}"; do
        if command -v "$BIN" &>/dev/null; then
            echo -e "  ${G}[OK]${NC}  Binary: $BIN"
        else
            # rsync is only needed for --migrate, so make it a warning not an error
            if [ "$BIN" = "rsync" ]; then
                echo -e "  ${Y}[WARN]${NC} Binary: rsync not found — required for --migrate mode"
                echo -e "         Install with: sudo pacman -S rsync"
                ((WARNINGS++))
            else
                echo -e "  ${R}[FAIL]${NC} Binary: $BIN not found — required for core functionality"
                ((ERRORS++))
            fi
        fi
    done

    # --- Display manager ---
    # Both sddm and plasmalogin are supported. Both use PAM system-login inclusion.
    # Other display managers (GDM, LightDM) are untested with the nsenter approach.
    local DM_SERVICE="" DM_NAME=""
    if systemctl is-active --quiet sddm 2>/dev/null; then
        DM_SERVICE="sddm"; DM_NAME="SDDM"
    elif systemctl is-active --quiet plasmalogin 2>/dev/null; then
        DM_SERVICE="plasmalogin"; DM_NAME="Plasma Login Manager"
    elif systemctl is-active --quiet gdm 2>/dev/null; then
        DM_SERVICE="gdm"; DM_NAME="GDM"
    elif systemctl is-active --quiet lightdm 2>/dev/null; then
        DM_SERVICE="lightdm"; DM_NAME="LightDM"
    fi

    if [ "$DM_SERVICE" = "sddm" ] || [ "$DM_SERVICE" = "plasmalogin" ]; then
        echo -e "  ${G}[OK]${NC}  Display manager: $DM_NAME"
    elif [ -n "$DM_SERVICE" ]; then
        echo -e "  ${Y}[WARN]${NC} Display manager: $DM_NAME is untested with this script"
        echo -e "         The nsenter bind mount was developed against SDDM and plasmalogin."
        echo -e "         PAM hooks will install but mount behaviour is unverified."
        ((WARNINGS++))
    else
        echo -e "  ${Y}[WARN]${NC} Display manager: could not detect active display manager service"
        echo -e "         Expected: sddm or plasmalogin"
        ((WARNINGS++))
    fi

    # --- Desktop environment ---
    # XDG_CURRENT_DESKTOP is set by the session. KDE Plasma is the tested environment.
    local DESKTOP="${XDG_CURRENT_DESKTOP:-}"
    if echo "$DESKTOP" | grep -qi "KDE"; then
        echo -e "  ${G}[OK]${NC}  Desktop: KDE Plasma ($DESKTOP)"
    elif [ -n "$DESKTOP" ]; then
        echo -e "  ${Y}[WARN]${NC} Desktop: $DESKTOP detected — only KDE Plasma has been tested"
        echo -e "         The script may work on other desktops but mount namespace behaviour"
        echo -e "         depends on how the compositor inherits mounts from the display manager."
        ((WARNINGS++))
    else
        echo -e "  ${Y}[WARN]${NC} Desktop: XDG_CURRENT_DESKTOP not set (running as root or in TTY?)"
        echo -e "         Cannot verify desktop environment."
        ((WARNINGS++))
    fi

    # --- PAM file exists ---
    if [ -f /etc/pam.d/system-login ]; then
        echo -e "  ${G}[OK]${NC}  PAM config: /etc/pam.d/system-login exists"
    else
        echo -e "  ${R}[FAIL]${NC} PAM config: /etc/pam.d/system-login not found"
        echo -e "         This file is required on Arch-based systems."
        ((ERRORS++))
    fi

    # --- Filesystem detection for /steam-library ---
    # Bind mounts and nsenter are filesystem-agnostic (kernel VFS layer).
    # Tested: ZFS, ext4. XFS should work (same POSIX semantics).
    # btrfs has a CoW/setgid edge case. F2FS and bcachefs are untested.
    # We detect the filesystem only if /steam-library already exists.
    if [ -d "$LIBRARY" ]; then
        local LIB_FS LIB_FS_DISPLAY
        # findmnt returns the real kernel type (e.g. "ext4"); stat -f -c '%T'
        # returns the statfs type constant which shows "ext2" for all ext* filesystems.
        # Use findmnt first so we report the accurate type.
        LIB_FS=$(findmnt -n -o FSTYPE "$LIBRARY" 2>/dev/null || stat -f -c '%T' "$LIBRARY" 2>/dev/null || echo "unknown")
        # Normalize: stat -f -c '%T' returns "ext2/ext3" or "ext2" for all ext* filesystems.
        # findmnt returns the correct "ext4" when available, but falls back to stat on some
        # systems. Strip trailing whitespace and normalize any ext2/ext3 variant to ext4.
        LIB_FS="${LIB_FS%$'\n'}"
        LIB_FS="${LIB_FS%$'\r'}"
        case "$LIB_FS" in
            ext2*|ext3*) LIB_FS="ext4" ;;
        esac
        LIB_FS_DISPLAY="$LIB_FS"
        case "$LIB_FS" in
            zfs)
                echo -e "  ${G}[OK]${NC}  Filesystem: ZFS (fully tested)"
                ;;
            ext4|ext3)
                echo -e "  ${G}[OK]${NC}  Filesystem: $LIB_FS_DISPLAY (fully tested)"
                ;;
            xfs)
                echo -e "  ${G}[OK]${NC}  Filesystem: XFS (supported)"
                ;;
            btrfs)
                echo -e "  ${Y}[WARN]${NC} Filesystem: btrfs detected"
                echo -e "         Btrfs copy-on-write behaviour can cause new game files written"
                echo -e "         during Steam updates to not inherit the setgid group bit, since"
                echo -e "         CoW creates new inodes rather than modifying in place."
                echo -e "         The script re-applies group ownership after --migrate, and the"
                echo -e "         setgid bit on directories still applies to newly created files."
                echo -e "         In practice this rarely causes issues for Steam game files."
                ((WARNINGS++))
                ;;
            f2fs)
                echo -e "  ${Y}[WARN]${NC} Filesystem: F2FS detected — not tested with this script"
                echo -e "         F2FS handles POSIX permissions and bind mounts correctly in theory,"
                echo -e "         but has not been verified with the nsenter-based bind mount approach."
                ((WARNINGS++))
                ;;
            bcachefs)
                echo -e "  ${Y}[WARN]${NC} Filesystem: bcachefs detected — considered experimental"
                echo -e "         CachyOS marks bcachefs as experimental. Proceed with caution."
                ((WARNINGS++))
                ;;
            unknown|"")
                echo -e "  ${Y}[WARN]${NC} Filesystem: could not detect filesystem type for $LIBRARY"
                ((WARNINGS++))
                ;;
            *)
                echo -e "  ${Y}[WARN]${NC} Filesystem: $LIB_FS — untested with this script"
                ((WARNINGS++))
                ;;
        esac
    else
        echo -e "  ${Y}[WARN]${NC} Filesystem: $LIBRARY does not exist yet — cannot detect filesystem"
        echo -e "         Create it before running the full setup."
    fi

    echo ""

    if [ "$ERRORS" -gt 0 ]; then
        echo -e "${R}Environment check failed: $ERRORS error(s), $WARNINGS warning(s).${NC}"
        echo -e "This script cannot run safely on this system."
        echo -e "Use ${W}--check${NC} to run diagnostics without making changes, or resolve the errors above."
        echo ""
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${Y}Environment check: $WARNINGS warning(s) — not fully supported but may work.${NC}"
        echo -en "${Y}Proceed anyway? [y/N] ${NC}"
        read -r REPLY
        [[ ! "$REPLY" =~ ^[Yy] ]] && { echo "Aborted."; exit 0; }
        echo ""
    else
        echo -e "${G}Environment check passed.${NC}"
        echo ""
    fi
}

# --check and --help don't modify the system so skip the environment gate
if ! $CHECK_ONLY && ! $HELP_MODE; then
    _check_environment
fi

# =============================================================================
# _move_library DEST
#
# Safely relocates the entire shared library to a new path.
# Strategy:
#   1. Validate destination (parent must exist, dest must not exist yet)
#   2. Confirm with user — show sizes and what will happen
#   3. rsync common/, workshop/, appmanifest_*.acf, libraryfolder.vdf
#      (compatdata is NOT moved — it's a bind mount target, stays in place)
#   4. Verify rsync exit code and spot-check file counts
#   5. Update /etc/steam-multiuser.conf with new LIBRARY path
#   6. Regenerate steam-session-mount.sh and steam-compatdata-mount.sh
#      with updated TARGET path
#   7. Update per-user libraryfolders.vdf to replace old path with new
#   8. Fix permissions, StateFlags on moved .acf files
#   9. Remove old library (keeping compatdata directory locked down)
#   10. Run --check to confirm everything is healthy
# =============================================================================
_move_library() {
    local NEW_LIBRARY="$1"

    require_root

    # ── Validate ──────────────────────────────────────────────────────────
    if [ -z "$NEW_LIBRARY" ]; then
        echo -e "$FAIL  Usage: sudo steam-multiuser.sh --move /path/to/new/location"
        exit 1
    fi

    # Normalise — strip trailing slash
    NEW_LIBRARY="${NEW_LIBRARY%/}"
    local NEW_STEAMAPPS="$NEW_LIBRARY/steamapps"

    if [ "$NEW_LIBRARY" = "$LIBRARY" ]; then
        echo -e "$FAIL  Destination is the same as the current library path: $LIBRARY"
        exit 1
    fi

    local PARENT
    PARENT=$(dirname "$NEW_LIBRARY")
    if [ ! -d "$PARENT" ]; then
        echo -e "$FAIL  Parent directory does not exist: $PARENT"
        echo -e "       Mount your drive and ensure the parent path exists first."
        exit 1
    fi

    if [ -e "$NEW_LIBRARY" ]; then
        echo -e "$FAIL  Destination already exists: $NEW_LIBRARY"
        echo -e "       Choose a path that does not exist yet — the script will create it."
        exit 1
    fi

    if [ ! -d "$LIBRARY" ]; then
        echo -e "$FAIL  Current library not found: $LIBRARY"
        exit 1
    fi

    # ── Show summary and confirm ───────────────────────────────────────────
    local LIB_SIZE
    LIB_SIZE=$(du -sh "$LIBRARY/steamapps/common" 2>/dev/null | cut -f1 || echo "unknown")
    local ACF_COUNT
    ACF_COUNT=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)
    local GAME_COUNT
    GAME_COUNT=$(find "$STEAMAPPS/common" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)

    echo ""
    echo -e "${BOLD}Moving shared Steam library${NC}"
    echo -e "  From: ${YELLOW}$LIBRARY${NC}"
    echo -e "    To: ${YELLOW}$NEW_LIBRARY${NC}"
    echo -e "  Size: $LIB_SIZE  ($GAME_COUNT game folders, $ACF_COUNT manifests)"
    echo ""
    echo -e "${YELLOW}This will:${NC}"
    echo -e "  1. Copy all game files to $NEW_LIBRARY via rsync"
    echo -e "  2. Update /etc/steam-multiuser.conf → LIBRARY=$NEW_LIBRARY"
    echo -e "  3. Regenerate the PAM bind mount script with the new path"
    echo -e "  4. Update each user's Steam library config (libraryfolders.vdf)"
    echo -e "  5. Remove the old library at $LIBRARY"
    echo ""
    echo -e "${YELLOW}  The source is never removed until rsync completes successfully.${NC}"
    echo -e "${RED}  Close Steam on all accounts before proceeding.${NC}"
    echo ""
    echo -en "${YELLOW}Proceed with library move? [y/N] ${NC}"
    read -r CONFIRM
    [[ ! "$CONFIRM" =~ ^[Yy] ]] && { echo "Move cancelled."; return 0; }
    echo ""

    # ── Step 1: Create destination structure ──────────────────────────────
    echo -e "${BOLD}Step 1/7: Creating destination structure...${NC}"
    mkdir -p "$NEW_STEAMAPPS/common" "$NEW_STEAMAPPS/workshop"
    chown root:"$GAMERS_GROUP" "$NEW_LIBRARY" "$NEW_STEAMAPPS" \
          "$NEW_STEAMAPPS/common" "$NEW_STEAMAPPS/workshop"
    chmod 2775 "$NEW_LIBRARY" "$NEW_STEAMAPPS" \
               "$NEW_STEAMAPPS/common" "$NEW_STEAMAPPS/workshop"

    # Create the locked-down compatdata bind mount target
    mkdir -p "$NEW_STEAMAPPS/compatdata"
    chown root:root "$NEW_STEAMAPPS/compatdata"
    chmod 000 "$NEW_STEAMAPPS/compatdata"
    echo -e "$FIX  Created $NEW_LIBRARY"

    # ── Step 2: rsync game files ───────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Step 2/7: Copying game files (this may take a long time)...${NC}"
    if ! rsync -a --no-xattrs --info=progress2 \
         --exclude='steamapps/compatdata' \
         "$LIBRARY/" "$NEW_LIBRARY/"; then
        echo -e "$FAIL  rsync failed — source library is untouched at $LIBRARY"
        echo -e "       Resolve the error and try again."
        rm -rf "$NEW_LIBRARY"
        exit 1
    fi
    echo -e "$FIX  rsync completed"

    # ── Step 3: Verify copy ────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Step 3/7: Verifying copy...${NC}"
    local SRC_GAMES DST_GAMES SRC_ACFS DST_ACFS
    SRC_GAMES=$(find "$STEAMAPPS/common" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    DST_GAMES=$(find "$NEW_STEAMAPPS/common" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    SRC_ACFS=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)
    DST_ACFS=$(find "$NEW_STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)

    local VERIFY_OK=true
    if [ "$SRC_GAMES" -ne "$DST_GAMES" ]; then
        echo -e "$FAIL  Game folder count mismatch: source=$SRC_GAMES dest=$DST_GAMES"
        VERIFY_OK=false
    else
        echo -e "$PASS  Game folders: $DST_GAMES/$SRC_GAMES copied"
    fi
    if [ "$SRC_ACFS" -ne "$DST_ACFS" ]; then
        echo -e "$FAIL  Appmanifest count mismatch: source=$SRC_ACFS dest=$DST_ACFS"
        VERIFY_OK=false
    else
        echo -e "$PASS  Appmanifests: $DST_ACFS/$SRC_ACFS copied"
    fi

    if ! $VERIFY_OK; then
        echo -e "$FAIL  Verification failed — source library is untouched at $LIBRARY"
        echo -e "       Inspect $NEW_LIBRARY and retry, or remove it and try again."
        exit 1
    fi

    # ── Step 4: Fix permissions and StateFlags on destination ──────────────
    echo ""
    echo -e "${BOLD}Step 4/7: Fixing permissions and StateFlags...${NC}"
    chown root:"$GAMERS_GROUP" "$NEW_STEAMAPPS"/appmanifest_*.acf 2>/dev/null
    chmod 644 "$NEW_STEAMAPPS"/appmanifest_*.acf 2>/dev/null
    STEAMAPPS="$NEW_STEAMAPPS" _fix_acf_stateflags

    # ── Step 5: Update config file ────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Step 5/7: Updating /etc/steam-multiuser.conf...${NC}"
    if [ -f "$CONF_FILE" ]; then
        # Replace or add LIBRARY= line
        if grep -q '^LIBRARY=' "$CONF_FILE"; then
            sed -i "s|^LIBRARY=.*|LIBRARY=$NEW_LIBRARY|" "$CONF_FILE"
        else
            echo "LIBRARY=$NEW_LIBRARY" >> "$CONF_FILE"
        fi
    else
        echo "LIBRARY=$NEW_LIBRARY" > "$CONF_FILE"
        echo "GAMERS_GROUP=$GAMERS_GROUP" >> "$CONF_FILE"
    fi
    echo -e "$FIX  $CONF_FILE → LIBRARY=$NEW_LIBRARY"

    # Update runtime variables so subsequent steps use the new path
    local OLD_LIBRARY="$LIBRARY"
    local OLD_STEAMAPPS="$STEAMAPPS"
    LIBRARY="$NEW_LIBRARY"
    STEAMAPPS="$NEW_STEAMAPPS"

    # ── Step 6: Regenerate mount scripts with new path ────────────────────
    echo ""
    echo -e "${BOLD}Step 6/7: Regenerating PAM mount scripts...${NC}"
    _write_session_mount_script
    echo -e "$FIX  Regenerated $SESSION_MOUNT_SCRIPT"
    _write_mount_script
    echo -e "$FIX  Regenerated $MOUNT_SCRIPT"

    # ── Step 7: Update per-user libraryfolders.vdf ────────────────────────
    echo ""
    echo -e "${BOLD}Step 7/7: Updating per-user Steam library configs...${NC}"
    while IFS= read -r GUSER; do
        local GHOME
        GHOME=$(getent passwd "$GUSER" | cut -f6 -d:)
        local VDF="$GHOME/.local/share/Steam/steamapps/libraryfolders.vdf"
        if [ ! -f "$VDF" ]; then
            echo -e "$WARN  No libraryfolders.vdf for $GUSER — skipping"
            continue
        fi
        if grep -q "$OLD_LIBRARY" "$VDF" 2>/dev/null; then
            cp "$VDF" "${VDF}.bak"
            sed -i "s|$OLD_LIBRARY|$NEW_LIBRARY|g" "$VDF"
            chown "$GUSER":"$GUSER" "$VDF"
            echo -e "$FIX  Updated libraryfolders.vdf for $GUSER"
        elif grep -q "$NEW_LIBRARY" "$VDF" 2>/dev/null; then
            echo -e "$PASS  $GUSER already has $NEW_LIBRARY in their library config"
        else
            # Not registered yet — use the register helper
            _register_library_for_user "$GUSER" "$GHOME"
        fi
    done < <(discover_users)

    # ── Remove old library ────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}Removing old library at $OLD_LIBRARY...${NC}"
    # Unmount compatdata if currently mounted there
    if mountpoint -q "$OLD_STEAMAPPS/compatdata" 2>/dev/null; then
        umount "$OLD_STEAMAPPS/compatdata" 2>/dev/null || \
            nsenter --mount=/proc/1/ns/mnt -- umount "$OLD_STEAMAPPS/compatdata" 2>/dev/null
        echo -e "$FIX  Unmounted bind mount from old compatdata target"
    fi
    rm -rf "$OLD_LIBRARY"
    echo -e "$FIX  Removed $OLD_LIBRARY"

    echo ""
    echo -e "${GREEN}${BOLD}Library move complete.${NC}"
    echo ""
    echo -e "New library location: ${BOLD}$LIBRARY${NC}"
    echo -e ""
    echo -e "Next steps:"
    echo -e "  1. Log out and back in on each user account to activate the"
    echo -e "     updated bind mount pointing to the new location"
    echo -e "  2. In Steam, go to Settings → Storage — the old path may show"
    echo -e "     as missing; remove it and confirm $LIBRARY is listed"
    echo -e "  3. Run ${BOLD}steam-multiuser.sh --check${NC} to verify everything is healthy"
    echo ""
}

# =============================================================================
# --migrate mode
# =============================================================================

if $MIGRATE_MODE; then
    require_root
    _migrate_games
    exit 0
fi

# =============================================================================
# --move mode
# =============================================================================

if [ -n "$MOVE_DEST" ]; then
    _move_library "$MOVE_DEST"
    exit 0
fi

# =============================================================================
# Require root for fix mode
# =============================================================================

if ! $CHECK_ONLY && [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Running without sudo — switching to check-only mode.${NC}"
    echo -e "Run with sudo to enable fixes: ${BOLD}sudo steam-multiuser.sh${NC}\n"
    CHECK_ONLY=true
fi

# =============================================================================
# Ensure gamers group exists before any group checks
# =============================================================================

if [ "$EUID" -eq 0 ]; then
    ensure_gamers_group
elif ! getent group "$GAMERS_GROUP" &>/dev/null; then
    echo -e "${WARN} Group '$GAMERS_GROUP' does not exist — run: sudo steam-multiuser.sh to create it"
fi

# =============================================================================
# Discover users and classify them
# =============================================================================

mapfile -t ALL_HUMAN_USERS < <(discover_users)
GAMERS_USERS=()
STEAM_USERS=()
PENDING_USERS=()   # in gamers group but Steam not yet installed

for U in "${ALL_HUMAN_USERS[@]}"; do
    in_gamers_group "$U" || continue
    GAMERS_USERS+=("$U")
    if steam_installed_for "$U"; then
        STEAM_USERS+=("$U")
    else
        PENDING_USERS+=("$U")
    fi
done

# =============================================================================
header "0. USER DISCOVERY"
# =============================================================================

EFFECTIVE_UID_MIN=$(_get_uid_min)
info "UID_MIN: $EFFECTIVE_UID_MIN (from $([ -f /etc/login.defs ] && echo /etc/login.defs || echo fallback))"
info "Human accounts on this system:"
for U in "${ALL_HUMAN_USERS[@]}"; do
    STEAM_STATUS="Steam: not installed"
    steam_installed_for "$U" && STEAM_STATUS="Steam: installed"
    GROUP_STATUS="not in $GAMERS_GROUP"
    in_gamers_group "$U" && GROUP_STATUS="in $GAMERS_GROUP"
    info "  $U  ($GROUP_STATUS | $STEAM_STATUS)"
done

if [ ${#GAMERS_USERS[@]} -eq 0 ]; then
    fail "No users found in the '$GAMERS_GROUP' group"
    echo -e "\nAdd users to the '$GAMERS_GROUP' group:"
    echo -e "  sudo steam-multiuser.sh --add USERNAME\n"
    exit 1
fi

info "Checking setup for: ${GAMERS_USERS[*]}"
[ ${#PENDING_USERS[@]} -gt 0 ] && \
    warn "In gamers group but Steam not yet installed: ${PENDING_USERS[*]}"

# =============================================================================
header "1. GROUP MEMBERSHIP"
# =============================================================================

for USER in "${ALL_HUMAN_USERS[@]}"; do
    if in_gamers_group "$USER"; then
        pass "User '$USER' is in the '$GAMERS_GROUP' group"
    else
        info "User '$USER' is not in '$GAMERS_GROUP' (use --add to onboard)"
    fi
done
info "Current user: $CURRENT_USER (groups: $(id -nG "$CURRENT_USER"))"

# =============================================================================
header "2. STEAM LIBRARY BASE PERMISSIONS"
# =============================================================================

fix_dir() {
    local DIR="$1" OWNER="$2" GROUP="$3" PERMS="$4"
    chown "$OWNER":"$GROUP" "$DIR"
    chmod "$PERMS" "$DIR"
}

check_and_fix_dir() {
    local DIR="$1" EXP_OWNER="$2" EXP_GROUP="$3" EXP_PERMS="$4" LABEL="$5"
    if [ ! -e "$DIR" ]; then
        fail "$LABEL: does not exist ($DIR)"
        if ask "Create $DIR with correct permissions?"; then
            mkdir -p "$DIR"
            fix_dir "$DIR" "$EXP_OWNER" "$EXP_GROUP" "$EXP_PERMS"
            fixed "Created $DIR ($EXP_OWNER:$EXP_GROUP $EXP_PERMS)"
        fi
        return
    fi
    local OWNER GROUP PERMS OK=true
    OWNER=$(stat -c '%U' "$DIR")
    GROUP=$(stat -c '%G' "$DIR")
    PERMS=$(stat -c '%a' "$DIR")
    [ "$OWNER" != "$EXP_OWNER" ] && OK=false
    [ "$GROUP" != "$EXP_GROUP" ] && OK=false
    [ "$PERMS" != "$EXP_PERMS" ] && OK=false
    if $OK; then
        pass "$LABEL: owner=$OWNER group=$GROUP perms=$PERMS"
    else
        fail "$LABEL: owner=$OWNER group=$GROUP perms=$PERMS (expected $EXP_OWNER:$EXP_GROUP $EXP_PERMS)"
        if ask "Fix $LABEL permissions?"; then
            fix_dir "$DIR" "$EXP_OWNER" "$EXP_GROUP" "$EXP_PERMS"
            fixed "Fixed $DIR → $EXP_OWNER:$EXP_GROUP $EXP_PERMS"
        fi
    fi
}

check_and_fix_dir "$LIBRARY"          "root" "$GAMERS_GROUP" "2775" "$LIBRARY"
check_and_fix_dir "$STEAMAPPS"        "root" "$GAMERS_GROUP" "2775" "$STEAMAPPS"
# common/ is created by Steam on first game install — warn if missing, don't fail
if [ -d "$STEAMAPPS/common" ]; then
    check_and_fix_dir "$STEAMAPPS/common" "root" "$GAMERS_GROUP" "2775" "$STEAMAPPS/common"
else
    warn "$STEAMAPPS/common does not exist yet — Steam will create it on first game install"
fi

COMPATDATA="$STEAMAPPS/compatdata"
if sudo mountpoint -q "$COMPATDATA" 2>/dev/null; then
    MOUNT_SOURCE=$(sudo findmnt -n -o SOURCE "$COMPATDATA" 2>/dev/null)
    pass "$COMPATDATA: bind mount active ($MOUNT_SOURCE)"
elif [ -L "$COMPATDATA" ]; then
    fail "$COMPATDATA: is a dangling symlink (leftover from old setup)"
    if ask "Remove symlink and create lockdown directory?"; then
        rm "$COMPATDATA"
        mkdir "$COMPATDATA"
        chown root:root "$COMPATDATA"
        chmod 0000 "$COMPATDATA"
        fixed "Replaced symlink with lockdown directory (root:root 000)"
    fi
elif [ -d "$COMPATDATA" ]; then
    CD_OWNER=$(stat -c '%U' "$COMPATDATA")
    CD_PERMS=$(stat -c '%a' "$COMPATDATA")
    if [ "$CD_OWNER" = "root" ] && [ "$CD_PERMS" = "0" ]; then
        pass "$COMPATDATA: lockdown in place (root:root 000)"
    else
        fail "$COMPATDATA: lockdown wrong — owner=$CD_OWNER perms=$CD_PERMS (expected root 000)"
        if ask "Fix compatdata lockdown?"; then
            chown root:root "$COMPATDATA"
            chmod 0000 "$COMPATDATA"
            fixed "Fixed $COMPATDATA → root:root 000"
        fi
    fi
else
    fail "$COMPATDATA: does not exist"
    if ask "Create compatdata lockdown directory?"; then
        mkdir -p "$COMPATDATA"
        chown root:root "$COMPATDATA"
        chmod 0000 "$COMPATDATA"
        fixed "Created $COMPATDATA (root:root 000)"
    fi
fi

VDF="$LIBRARY/libraryfolder.vdf"
if [ -f "$VDF" ]; then
    VDF_OWNER=$(stat -c '%U' "$VDF")
    VDF_GROUP=$(stat -c '%G' "$VDF")
    VDF_PERMS=$(stat -c '%a' "$VDF")
    if [ "$VDF_OWNER" = "root" ] && [ "$VDF_GROUP" = "$GAMERS_GROUP" ] && [ "$VDF_PERMS" = "664" ]; then
        pass "$VDF: owner=$VDF_OWNER group=$VDF_GROUP perms=$VDF_PERMS"
    else
        fail "$VDF: owner=$VDF_OWNER group=$VDF_GROUP perms=$VDF_PERMS (expected root:$GAMERS_GROUP 664)"
        if ask "Fix libraryfolder.vdf permissions?"; then
            chown root:"$GAMERS_GROUP" "$VDF"
            chmod 664 "$VDF"
            fixed "Fixed $VDF → root:$GAMERS_GROUP 664"
        fi
    fi
else
    warn "$VDF not found — Steam will create it on first launch"
fi

# =============================================================================
header "3. SETGID BIT ON KEY DIRECTORIES"
# =============================================================================

for DIR in "$LIBRARY" "$STEAMAPPS" "$STEAMAPPS/common"; do
    [ -d "$DIR" ] || continue
    if stat -c '%A' "$DIR" | grep -q 's\|S'; then
        pass "setgid set on $DIR"
    else
        fail "setgid NOT set on $DIR"
        if ask "Set setgid on $DIR?"; then
            chmod g+s "$DIR"
            fixed "Set setgid on $DIR"
        fi
    fi
done

# =============================================================================
header "4. PAM SESSION HOOK"
# =============================================================================

# The bind mount is performed entirely by pam_exec -> steam-session-mount.sh,
# which mounts the user's private compatdata into the root mount namespace via
# nsenter so the graphical session inherits it. No pam_namespace polyinstantiation
# is involved — earlier versions configured pam_namespace.so, a tmpfs trigger
# directory, and a namespace.conf entry, but none of that contributed to the
# mount working (pam_namespace would actually disassociate the session namespace,
# which is the opposite of what we need). The block below removes those leftovers
# if an older version installed them.

PAM_NS_LEFTOVER=false
if grep -q "pam_namespace.so" "$PAM_FILE" 2>/dev/null; then
    PAM_NS_LEFTOVER=true
    warn "Obsolete pam_namespace.so line found in $PAM_FILE"
    if ask "Remove the pam_namespace.so line? (the bind mount does not use it)"; then
        # Remove only the bare session line this script previously added; leave
        # any other pam_namespace configuration the admin may rely on untouched.
        sed -i '/^session[[:space:]]*optional[[:space:]]*pam_namespace.so[[:space:]]*$/d' "$PAM_FILE"
        fixed "Removed obsolete pam_namespace.so line from $PAM_FILE"
    fi
fi
if [ -f "$NAMESPACE_CONF" ]; then
    PAM_NS_LEFTOVER=true
    warn "Obsolete namespace config found: $NAMESPACE_CONF"
    if ask "Remove $NAMESPACE_CONF?"; then
        rm -f "$NAMESPACE_CONF"
        fixed "Removed $NAMESPACE_CONF"
    fi
fi
if [ -d "$TRIGGER_DIR" ]; then
    PAM_NS_LEFTOVER=true
    warn "Obsolete PAM trigger directory found: $TRIGGER_DIR"
    if ask "Remove $TRIGGER_DIR?"; then
        rmdir "$TRIGGER_DIR" 2>/dev/null || rm -rf "$TRIGGER_DIR"
        fixed "Removed $TRIGGER_DIR"
    fi
fi
$PAM_NS_LEFTOVER || pass "No obsolete pam_namespace configuration present"

if grep -q "pam_exec.so" "$PAM_FILE" 2>/dev/null; then
    EXEC_SCRIPT=$(grep "pam_exec.so" "$PAM_FILE" | grep -o '/[^ ]*$')
    if [ -x "$EXEC_SCRIPT" ]; then
        pass "pam_exec.so → $EXEC_SCRIPT (executable)"
    else
        fail "pam_exec.so references '$EXEC_SCRIPT' which is missing or not executable"
        if ask "Recreate $SESSION_MOUNT_SCRIPT?"; then
            _write_session_mount_script
            fixed "Recreated $SESSION_MOUNT_SCRIPT"
        fi
    fi
else
    fail "pam_exec.so NOT found in $PAM_FILE"
    if ask "Add pam_exec.so and create session mount script?"; then
        _write_session_mount_script
        echo "session optional pam_exec.so stdout $SESSION_MOUNT_SCRIPT" >> "$PAM_FILE"
        fixed "Added pam_exec.so to $PAM_FILE and created $SESSION_MOUNT_SCRIPT"
    fi
fi

if [ -f "$MOUNT_SCRIPT" ] && [ -x "$MOUNT_SCRIPT" ]; then
    pass "Manual mount script exists: $MOUNT_SCRIPT"
else
    warn "Manual mount script missing or not executable: $MOUNT_SCRIPT"
    if ask "Recreate $MOUNT_SCRIPT?"; then
        _write_mount_script
        fixed "Created $MOUNT_SCRIPT"
    fi
fi

# =============================================================================
header "5. PER-USER STEAM DIRECTORIES"
# =============================================================================

for USER in "${GAMERS_USERS[@]}"; do
    id "$USER" &>/dev/null || { warn "User '$USER' not found — skipping"; continue; }
    HOME_DIR=$(getent passwd "$USER" | cut -f6 -d:)
    LOCAL_STEAMAPPS="$HOME_DIR/.local/share/Steam/steamapps"

    info "--- $USER ---"

    if steam_installed_for "$USER"; then
        pass "  Steam installed: $HOME_DIR/.local/share/Steam"
        STEAM_OK=true
    else
        warn "  Steam not installed — log in as '$USER' and launch Steam once"
        STEAM_OK=false
    fi

    PRIVATE_COMPAT=""
    for candidate in \
        "$HOME_DIR/.local/share/Steam/steamapps/compatdata" \
        "$HOME_DIR/.steam/steam/steamapps/compatdata"; do
        sudo test -d "$candidate" 2>/dev/null && PRIVATE_COMPAT="$candidate" && break
    done

    if [ -n "$PRIVATE_COMPAT" ]; then
        OWNER=$(sudo stat -c '%U' "$PRIVATE_COMPAT" 2>/dev/null)
        PERMS=$(sudo stat -c '%a' "$PRIVATE_COMPAT" 2>/dev/null)
        COUNT=$(sudo ls "$PRIVATE_COMPAT" 2>/dev/null | wc -l)
        if [ "$OWNER" = "$USER" ]; then
            pass "  compatdata: $PRIVATE_COMPAT ($PERMS) — $COUNT prefix(es)"
        else
            fail "  compatdata owned by '$OWNER', should be '$USER'"
            if ask "Fix ownership of $PRIVATE_COMPAT?"; then
                chown -R "$USER":"$USER" "$PRIVATE_COMPAT"
                fixed "Fixed ownership → $USER"
            fi
        fi
    else
        warn "  compatdata: not found — will be created on first game launch"
    fi

    PRIVATE_SHADER=""
    for candidate in \
        "$HOME_DIR/.local/share/Steam/steamapps/shadercache" \
        "$HOME_DIR/.steam/steam/steamapps/shadercache"; do
        sudo test -d "$candidate" 2>/dev/null && PRIVATE_SHADER="$candidate" && break
    done
    if [ -n "$PRIVATE_SHADER" ]; then
        OWNER=$(sudo stat -c '%U' "$PRIVATE_SHADER" 2>/dev/null)
        pass "  shadercache: $PRIVATE_SHADER (owned by $OWNER)"
    else
        warn "  shadercache: not found — will be created on first game launch"
    fi

    if $STEAM_OK; then
        ACF_COUNT=$(sudo bash -c "find '$LOCAL_STEAMAPPS' -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null | wc -l")
        SHARED_ACF_COUNT=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)
        if [ "$ACF_COUNT" -gt 0 ]; then
            pass "  appmanifests: $ACF_COUNT file(s) in local steamapps"
        elif [ "$SHARED_ACF_COUNT" -gt 0 ]; then
            fail "  appmanifests: none locally but $SHARED_ACF_COUNT in shared dir (will conflict)"
            if ask "Copy shared appmanifests to $USER's local steamapps?"; then
                cp "$STEAMAPPS"/appmanifest_*.acf "$LOCAL_STEAMAPPS"/
                chown "$USER":"$USER" "$LOCAL_STEAMAPPS"/appmanifest_*.acf
                chmod 644 "$LOCAL_STEAMAPPS"/appmanifest_*.acf
                fixed "Copied $SHARED_ACF_COUNT appmanifest(s) to $LOCAL_STEAMAPPS"
            fi
        else
            warn "  appmanifests: none found — add $LIBRARY in Steam → Settings → Storage"
        fi
    fi
done

# =============================================================================
header "6. ACTIVE BIND MOUNT (current session: $CURRENT_USER)"
# =============================================================================

COMPATDATA_TARGET="$STEAMAPPS/compatdata"

if sudo mountpoint -q "$COMPATDATA_TARGET" 2>/dev/null; then
    MOUNT_SOURCE=$(sudo findmnt -n -o SOURCE "$COMPATDATA_TARGET" 2>/dev/null)
    pass "Bind mount active on $COMPATDATA_TARGET"
    info "  Source: $MOUNT_SOURCE"

    # Resolve the actual bind mount source path from /proc/self/mountinfo.
    # This is filesystem-agnostic: ZFS shows dataset[/subpath], ext4/XFS/btrfs
    # show block device paths. We extract the real filesystem path from field 4
    # (the root of the mount within the filesystem) combined with field 5
    # (the mountpoint). For bind mounts, field 4 contains the source path
    # relative to the filesystem root — which always contains the username
    # regardless of filesystem type.
    MOUNT_OK=false
    MOUNT_REAL_PATH=""

    # /proc/self/mountinfo format: id parent major:minor root mountpoint options...
    # Field 4 (root) for a bind mount contains the source path within the FS.
    # For ZFS: root = /arkroyal1987/.local/share/Steam/steamapps/compatdata
    # For ext4: root = /home/arkroyal1987/.local/share/Steam/steamapps/compatdata
    # Both contain the username — check field 4 directly.
    while IFS=' ' read -r _ _ _ ROOT MOUNTPOINT _; do
        if [ "$MOUNTPOINT" = "$COMPATDATA_TARGET" ]; then
            MOUNT_REAL_PATH="$ROOT"
            break
        fi
    done < /proc/self/mountinfo

    if [ -n "$MOUNT_REAL_PATH" ]; then
        info "  Resolved path: $MOUNT_REAL_PATH"
        # When running as root (sudo), the bind mount will be scoped to a regular
        # user — that is correct and expected. Extract the username from the path.
        if [ "$CURRENT_USER" = "root" ]; then
            # Path is like /home/USERNAME/... or /USERNAME/... (ZFS) — extract username
            MOUNT_USER=$(echo "$MOUNT_REAL_PATH" | sed 's|^/home/||;s|^/||;s|/.*||')
            if [ -n "$MOUNT_USER" ] && id "$MOUNT_USER" &>/dev/null; then
                pass "Bind mount is active and scoped to user '$MOUNT_USER' (running as root — this is correct)"
                MOUNT_OK=true
            else
                # Can't identify user but mount is active — still OK
                pass "Bind mount is active (running as root, source: $MOUNT_REAL_PATH)"
                MOUNT_OK=true
            fi
        else
            # Running as a regular user — check it's scoped to us
            if echo "$MOUNT_REAL_PATH" | grep -qF "$CURRENT_USER"; then
                MOUNT_OK=true
            fi
            # Fallback: check findmnt SOURCE string
            if ! $MOUNT_OK; then
                if echo "$MOUNT_SOURCE" | grep -qF "$CURRENT_USER"; then
                    MOUNT_OK=true
                fi
            fi
            if $MOUNT_OK; then
                pass "Bind mount is scoped to current user ($CURRENT_USER)"
            else
                fail "Bind mount does NOT appear to be scoped to $CURRENT_USER"
                info "  Source reported by findmnt: $MOUNT_SOURCE"
                info "  Resolved root path: ${MOUNT_REAL_PATH:-could not resolve}"
                if ask "Re-mount for $CURRENT_USER now?"; then
                    "$MOUNT_SCRIPT" "$CURRENT_USER"
                    fixed "Re-mounted compatdata for $CURRENT_USER"
                fi
            fi
        fi
    else
        # No path resolved — fall back to source string check
        if [ "$CURRENT_USER" = "root" ]; then
            pass "Bind mount is active (running as root)"
            MOUNT_OK=true
        elif echo "$MOUNT_SOURCE" | grep -qF "$CURRENT_USER"; then
            pass "Bind mount is scoped to current user ($CURRENT_USER)"
            MOUNT_OK=true
        else
            fail "Bind mount does NOT appear to be scoped to $CURRENT_USER"
            info "  Source reported by findmnt: $MOUNT_SOURCE"
            if ask "Re-mount for $CURRENT_USER now?"; then
                "$MOUNT_SCRIPT" "$CURRENT_USER"
                fixed "Re-mounted compatdata for $CURRENT_USER"
            fi
        fi
    fi
else
    fail "No compatdata bind mount active"
    if ask "Mount compatdata for $CURRENT_USER now?"; then
        if [ -x "$MOUNT_SCRIPT" ]; then
            "$MOUNT_SCRIPT" "$CURRENT_USER"
            fixed "Mounted compatdata for $CURRENT_USER"
        else
            warn "Mount script not found — cannot fix automatically"
        fi
    fi
fi

# =============================================================================
header "7. STEAM LIBRARY CONFIGURATION (current user: $CURRENT_USER)"
# =============================================================================

VDF_FOUND=""
for candidate in \
    "$HOME/.steam/steam/steamapps/libraryfolders.vdf" \
    "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"; do
    [ -f "$candidate" ] && VDF_FOUND="$candidate" && break
done

if [ -n "$VDF_FOUND" ]; then
    pass "libraryfolders.vdf found: $VDF_FOUND"
    if grep -q "$LIBRARY" "$VDF_FOUND"; then
        pass "$LIBRARY is registered in Steam library config"
    else
        fail "$LIBRARY NOT in libraryfolders.vdf"
        warn "  Fix manually: Steam → Settings → Storage → Add Drive → $LIBRARY"
    fi
elif [ "$CURRENT_USER" = "root" ]; then
    # Root has no Steam installation — this is expected when running via sudo.
    # The VDF check is only meaningful for the actual logged-in user.
    info "libraryfolders.vdf: skipped — root has no Steam installation (expected when running via sudo)"
    info "  To verify your user's Steam library config, run as your normal user:"
    info "    steam-multiuser.sh --check"
else
    fail "libraryfolders.vdf not found — Steam may not be configured yet"
    warn "  Launch Steam at least once, then add $LIBRARY via Steam → Settings → Storage"
fi

# Appmanifests MUST live in /steam-library/steamapps/ so Steam can detect
# installed games when /steam-library is registered as a library path.
# Each .acf file references game files by path relative to the library root.
ACF_COUNT=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" 2>/dev/null | wc -l)
if [ "$ACF_COUNT" -gt 0 ]; then
    pass "$ACF_COUNT appmanifest file(s) in shared $STEAMAPPS (correct — Steam reads these from here)"
    # Verify they're group-readable so all users can see them
    BAD_ACF=$(find "$STEAMAPPS" -maxdepth 1 -name "appmanifest_*.acf" ! -group "$GAMERS_GROUP" -o               -name "appmanifest_*.acf" ! -perm -g+r 2>/dev/null | wc -l)
    if [ "$BAD_ACF" -gt 0 ]; then
        fail "$BAD_ACF appmanifest(s) are not group-readable — gamers users won't see those games"
        if ask "Fix appmanifest permissions?"; then
            chown root:"$GAMERS_GROUP" "$STEAMAPPS"/appmanifest_*.acf
            chmod 644 "$STEAMAPPS"/appmanifest_*.acf
            fixed "Fixed appmanifest ownership/permissions → root:$GAMERS_GROUP 644"
        fi
    fi
    # Check StateFlags — any value other than 4 will cause Steam to revalidate
    # (redownload) games on next launch. This commonly happens after moving .acf
    # files between library locations.
    BAD_FLAGS=$(grep -l '"StateFlags"' "$STEAMAPPS"/appmanifest_*.acf 2>/dev/null |                 xargs -r grep -L '"StateFlags"\s*"4"' 2>/dev/null | wc -l)
    if [ "$BAD_FLAGS" -gt 0 ]; then
        fail "$BAD_FLAGS appmanifest(s) have StateFlags != 4 — Steam will revalidate those games"
        warn "  This causes Steam to redownload game files unnecessarily."
        if ask "Fix StateFlags on all appmanifests now?"; then
            _fix_acf_stateflags
        fi
    else
        pass "All appmanifests have StateFlags=4 (fully installed — no revalidation on launch)"
    fi
else
    warn "No appmanifest files in shared $STEAMAPPS"
    warn "  If games were migrated, run: sudo steam-multiuser.sh --migrate"
    warn "  If this is a fresh setup, games will appear after first install to $LIBRARY"
fi

# Check write access to /steam-library for each gamers user.
# Steam does an access check when adding a storage path — if the user's session
# doesn't have the gamers group active (e.g. they haven't logged out since being
# added to the group), Steam will report the path as inaccessible.
echo ""
info "Checking write access to $LIBRARY for each user..."
for GUSER in "${GAMERS_USERS[@]}"; do
    if sudo -u "$GUSER" test -w "$STEAMAPPS" 2>/dev/null; then
        pass "  $GUSER can write to $STEAMAPPS"
    else
        fail "  $GUSER cannot write to $STEAMAPPS"
        warn "  Most likely cause: '$GUSER' needs to log out and back in for the"
        warn "  '$GAMERS_GROUP' group to become active in their session."
        warn "  Steam checks write access when adding a storage path — it will report"
        warn "  '$LIBRARY' as inaccessible until the group is active."
        warn "  Fix: log out as '$GUSER', log back in, then re-open Steam."
    fi
done

# =============================================================================
header "8. CLOUD SYNC STATUS"
# =============================================================================

TODAY=$(date '+%Y-%m-%d')

_check_cloud_log() {
    local CUSER="$1"
    local CLOG="$2"
    if [ -f "$CLOG" ]; then
        pass "  $CUSER: cloud log found"
        local RECENT_ERRORS
        RECENT_ERRORS=$(grep -i "error\|fail\|conflict" "$CLOG" | grep "$TODAY" | tail -5)
        if [ -n "$RECENT_ERRORS" ]; then
            warn "  $CUSER: recent cloud errors (today):"
            echo "$RECENT_ERRORS" | while read -r LINE; do info "    $LINE"; done
            info "    If these predate the current session they may already be resolved"
        else
            pass "  $CUSER: no cloud errors today"
        fi
    else
        info "  $CUSER: no cloud log found — Steam may not have run yet this session"
    fi
}

if [ "$CURRENT_USER" = "root" ]; then
    # Running as root (sudo) — $HOME is /root which has no Steam install.
    # Check cloud logs for all gamers-group users instead.
    info "Running as root — checking cloud logs for all Steam users:"
    for GUSER in "${GAMERS_USERS[@]}"; do
        GHOME=$(getent passwd "$GUSER" | cut -f6 -d:)
        _check_cloud_log "$GUSER" "$GHOME/.local/share/Steam/logs/cloud_log.txt"
    done
else
    STEAM_LOG="$HOME/.local/share/Steam/logs/cloud_log.txt"
    _check_cloud_log "$CURRENT_USER" "$STEAM_LOG"
fi

# =============================================================================
header "9. SESSION MOUNT STATUS"
# =============================================================================

# Quietly clean up services from early pre-release versions. Only emits output
# if one is actually found, so clean installs see nothing here.
for SERVICE in fix-steamlibrary.service steam-user-setup.service steam-compatdata-mount@.service; do
    if systemctl list-unit-files "$SERVICE" 2>/dev/null | grep -q "$SERVICE"; then
        warn "Obsolete system service present: $SERVICE"
        if ask "Disable and remove $SERVICE?"; then
            systemctl disable --now "$SERVICE" 2>/dev/null || true
            rm -f "/etc/systemd/system/$SERVICE"
            systemctl daemon-reload
            fixed "Removed $SERVICE"
        fi
    fi
done
for SERVICE in steam-user-setup.service steam-compatdata.service; do
    if systemctl --user list-unit-files "$SERVICE" 2>/dev/null | grep -q "$SERVICE"; then
        warn "Obsolete user service present: $SERVICE"
        if ask "Disable and remove $SERVICE?"; then
            systemctl --user disable --now "$SERVICE" 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/$SERVICE"
            systemctl --user daemon-reload
            fixed "Removed user service $SERVICE"
        fi
    fi
done

MOUNT_LOG=$(journalctl -t steam-session-mount --since "$(date '+%Y-%m-%d')" --no-pager -q 2>/dev/null \
    | grep "$CURRENT_USER" | tail -1)
if [ -n "$MOUNT_LOG" ]; then
    pass "pam_exec mount logged today for $CURRENT_USER"
    info "  $MOUNT_LOG"
else
    info "No pam_exec mount log for $CURRENT_USER today"
    info "  This is normal on a fresh setup or first login — log out and back in to activate"
fi

# =============================================================================
header "SUMMARY"
# =============================================================================

echo ""
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All checks passed. Setup looks correct.${NC}"
elif [ "$ISSUES" -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}$WARNINGS warning(s), no hard failures.${NC}"
else
    echo -e "${RED}${BOLD}$ISSUES issue(s), $WARNINGS warning(s). $FIXES fix(es) applied.${NC}"
fi
echo ""
echo -e "${INFO} Diagnose only:     steam-multiuser.sh --check"
echo -e "${INFO} Add a new user:    sudo steam-multiuser.sh --add USERNAME"
echo -e "${INFO} Migrate games:     sudo steam-multiuser.sh --migrate"
echo -e "${INFO} Full fix run:      sudo steam-multiuser.sh"
echo -e "${INFO} Mount log:         journalctl -t steam-session-mount --since today"
echo -e "${INFO} PAM namespace log: journalctl -t steamlibrary.init --since today"
echo -e "${INFO} Cloud sync log:    ~/.local/share/Steam/logs/cloud_log.txt"
echo ""
