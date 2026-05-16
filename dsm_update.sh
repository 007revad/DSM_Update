#!/usr/bin/env bash
#------------------------------------------------------------------------------
# dsm_update.sh - Scheduled DSM update script
# Supports nano/security updates (updateType=nano) and full updates (updateType=system)
# Downloads .pat file, verifies MD5 if available, applies update, then cleans up
#
# Usage:
#   dsm_update.sh           - Check for updates and install if available
#   dsm_update.sh --dry-run - Check and report only, do not download or install
#   dsm_update.sh --force-check - Re-run synoupgrade --check before proceeding
#
# Recommended: Add to Synology Task Scheduler as a root scheduled task
# e.g. daily at 3:00am: /volume1/scripts/dsm_update.sh
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Configuration

# Temporary directory for .pat downloads (cleaned up after install)
# $$ gets the PID of the script
PAT_DIR="/tmp/dsm_update_$$"

# Log file
LOG_FILE="/var/log/dsm_update.log"

# Maximum log file size in bytes before rotation (default 1MB)
LOG_MAX_SIZE=1048576

# synodsmnotify user to receive notifications (leave empty to notify all admins)
# If not empty all admins and users will receive notifications
NOTIFY_USER=""


#------------------------------------------------------------------------------
# Internals - do not edit below

DRY_RUN=0
FORCE_CHECK=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)      DRY_RUN=1 ;;
        --force-check)  FORCE_CHECK=1 ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--dry-run] [--force-check]"
            exit 1
            ;;
    esac
done

#------------------------------------------------------------------------------
# Logging

log(){ 
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

rotate_log(){ 
    if [[ -f "$LOG_FILE" ]] && [[ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -ge "$LOG_MAX_SIZE" ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotated."
    fi
}

#------------------------------------------------------------------------------
# Notifications

notify(){ 
    local title="$1"
    local msg="$2"
    log "NOTIFY: $title - $msg"
    if command -v synodsmnotify > /dev/null 2>&1; then
        if [[ -n "$NOTIFY_USER" ]]; then
            synodsmnotify "@administrators" "$title" "$msg" 2>/dev/null || true
            synodsmnotify "$NOTIFY_USER" "$title" "$msg" 2>/dev/null || true
        else
            synodsmnotify "@administrators" "$title" "$msg" 2>/dev/null || true
        fi
    fi
}

#------------------------------------------------------------------------------
# Cleanup

# shellcheck disable=SC2317  # Command appears to be unreachable
cleanup(){ 
    if [[ -d "$PAT_DIR" ]]; then
        log "Cleaning up temporary directory: $PAT_DIR"
        rm -rf "$PAT_DIR"
    fi
}

trap cleanup EXIT

#------------------------------------------------------------------------------
# Main

# Check running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "ERROR This script must be run as sudo!"
    exit 1
fi

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology and run it from there."
    exit 1  # Not a Synology NAS
fi

rotate_log
log "========================================"
log "DSM update check started${DRY_RUN:+ (dry-run mode)}"

# Get model name for notifications
MODEL=$(synogetkeyvalue /etc/syno_info upnpmodelname 2>/dev/null || echo "Unknown")
log "Model: $MODEL"

# Optionally force a fresh check from Synology servers
if [[ "$FORCE_CHECK" -eq 1 ]]; then
    log "Running synoupgrade --check ..."
    synoupgrade --check > /dev/null 2>&1
fi

# Read cached check result
UPDATE_JSON=$(cat /var/update/check_result/update 2>/dev/null)

# If no cached result, run a check now
if [[ -z "$UPDATE_JSON" ]]; then
    log "No cached check result found, running synoupgrade --check ..."
    synoupgrade --check > /dev/null 2>&1
    UPDATE_JSON=$(cat /var/update/check_result/update 2>/dev/null)
fi

if [[ -z "$UPDATE_JSON" ]]; then
    log "ERROR: Unable to retrieve update information."
    notify "DSM Update Error" "[$MODEL] Unable to retrieve update information."
    exit 1
fi

# Parse fields
AVAILABLE=$(echo "$UPDATE_JSON" | grep -o '"blAvailable":true')
if [[ -z "$AVAILABLE" ]]; then
    log "No update available. DSM is up to date."
    exit 0
fi

UPDATE_TYPE=$(echo "$UPDATE_JSON" | grep -o '"updateType":"[^"]*"' | cut -d'"' -f4)
BUILD=$(echo "$UPDATE_JSON" | grep -o '"iBuildNumber":[0-9]*' | cut -d: -f2)
NANO=$(echo "$UPDATE_JSON" | grep -o '"iNano":[0-9]*' | cut -d: -f2)
UNIQUE=$(echo "$UPDATE_JSON" | grep -o '"strUnique":"[^"]*"' | cut -d'"' -f4)
#MAJOR=$(echo "$UPDATE_JSON" | grep -o '"iMajor":[0-9]*' | head -1 | cut -d: -f2)
#MINOR=$(echo "$UPDATE_JSON" | grep -o '"iMinor":[0-9]*' | head -1 | cut -d: -f2)
#MICRO=$(echo "$UPDATE_JSON" | grep -o '"iMicro":[0-9]*' | cut -d: -f2)

log "Update available: type=$UPDATE_TYPE build=$BUILD nano=$NANO unique=$UNIQUE"

# Build URL and filename based on update type
case "$UPDATE_TYPE" in
    nano)
        # Nano/security update: use synology_<platform>_<model>.pat naming
        URL="https://global.synologydownload.com/download/DSM/criticalupdate/update_pack/${BUILD}-${NANO}/${UNIQUE}.pat"
        PAT_FILENAME="${UNIQUE}_${BUILD}-${NANO}.pat"
        MD5=""
        ;;
    system)
        # Full DSM update: URL is provided directly in the JSON
        URL=$(echo "$UPDATE_JSON" | grep -o '"strLink":"[^"]*"' | cut -d'"' -f4)
        MD5=$(echo "$UPDATE_JSON" | grep -o '"strCheckSum":"[^"]*"' | cut -d'"' -f4)
        # Derive filename from URL, decode %2B -> +
        PAT_FILENAME=$(echo "$URL" | grep -o '[^/]*\.pat$' | sed 's/%2B/+/g')
        if [[ -z "$URL" ]]; then
            log "ERROR: Could not extract download URL from update JSON for system update."
            notify "DSM Update Error" "[$MODEL] Could not extract download URL for system update."
            exit 1
        fi
        ;;
    *)
        log "ERROR: Unknown update type '$UPDATE_TYPE' - manual intervention required."
        notify "DSM Update Error" "[$MODEL] Unknown update type '$UPDATE_TYPE'. Manual update required."
        exit 1
        ;;
esac

log "Download URL: $URL"
log "Filename: $PAT_FILENAME"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: Would download and install: $PAT_FILENAME"
    notify "DSM Update Available (dry-run)" "[$MODEL] $UPDATE_TYPE update available: build $BUILD nano $NANO. Dry-run mode, no action taken."
    exit 0
fi

# Create temp directory and download
mkdir -p "$PAT_DIR" || { log "ERROR: Could not create temp directory $PAT_DIR"; exit 1; }
PAT_FILE="${PAT_DIR}/${PAT_FILENAME}"

log "Downloading $PAT_FILENAME ..."
if ! wget -q -O "$PAT_FILE" "$URL"; then
    log "ERROR: Download failed for $URL"
    notify "DSM Update Error" "[$MODEL] Download failed for $PAT_FILENAME."
    exit 1
fi

# Verify file exists and is non-empty
if [[ ! -s "$PAT_FILE" ]]; then
    log "ERROR: Downloaded file is empty or missing: $PAT_FILE"
    notify "DSM Update Error" "[$MODEL] Downloaded .pat file is empty."
    exit 1
fi

log "Download complete: $(du -h "$PAT_FILE" | cut -f1)"

# MD5 verification if checksum is available
if [[ -n "$MD5" ]]; then
    log "Verifying MD5 checksum ..."
    ACTUAL_MD5=$(md5sum "$PAT_FILE" | cut -d' ' -f1)
    if [[ "$ACTUAL_MD5" != "$MD5" ]]; then
        log "ERROR: MD5 mismatch! Expected=$MD5 Got=$ACTUAL_MD5"
        notify "DSM Update Error" "[$MODEL] MD5 verification failed for $PAT_FILENAME."
        exit 1
    fi
    log "MD5 verified OK ($MD5)"
else
    log "No MD5 checksum available for this update type, skipping verification."
fi

# Apply the update
log "Applying update: synoupgrade --patch $PAT_FILE"
notify "DSM Update Starting" "[$MODEL] Applying $UPDATE_TYPE update: build $BUILD nano $NANO. NAS will reboot."

PATCH_OUTPUT=$(synoupgrade --patch "$PAT_FILE" 2>&1)
PATCH_EXIT=$?

log "synoupgrade output: $PATCH_OUTPUT"

if [[ "$PATCH_EXIT" -ne 0 ]]; then
    log "ERROR: synoupgrade --patch failed with exit code $PATCH_EXIT"
    notify "DSM Update Failed" "[$MODEL] synoupgrade --patch failed. Check $LOG_FILE for details."
    exit 1
fi

# Check output JSON for success field
if echo "$PATCH_OUTPUT" | grep -q '"success":true'; then
    log "Update applied successfully."
    notify "DSM Update Success" "[$MODEL] $UPDATE_TYPE update applied successfully. NAS is rebooting."
else
    log "WARNING: synoupgrade exited 0 but success:true not found in output."
    notify "DSM Update Warning" "[$MODEL] Update may not have applied correctly. Check $LOG_FILE."
fi

log "DSM update script finished."
exit 0

