#!/bin/bash

# ==========================================================
# Weekly Main Unraid -> Backup Unraid Backup
# Version: v1.2.3
#
# Main/source server:        172.20.30.251
# Backup/destination server: 172.20.30.250
# Backup server BMC/IPMI:    172.20.30.136
# BMC user:                  lugocloud
#
# Uses existing Docker container on MAIN server:
#   IPMI-Tools
#
# Backup behavior:
#   - NO DELETE from backup server
#   - Excludes /mnt/user/CCTVStorage
#   - Excludes /mnt/user/BackupReports from replication
#   - Excludes appdata/ipmi_tools/backup_bmc.pass from replication
#   - Backs up appdata and system first while MAIN Docker is disabled
#   - Re-enables MAIN Docker after critical shares complete
#   - Continues remaining shares while MAIN Docker is running
#   - Excludes system/docker/docker.img and system/libvirt/libvirt.img
#   - Treats rsync code 24 as a warning
#   - Powers destination on with IPMI and off with shutdown -h now
#   - Uses PID lock directory, not flock, so Docker cannot retain the lock
#   - Tracks itemized transfer changes and calls a report helper on success
#   - Runs report helper with bash because Unraid /boot files are non-executable
#   - Stores verbose logs/reports on /mnt/user/BackupReports, not USB flash
#   - Generates PDF copies of completed reports for Paperless GPT ingestion
#   - Copies completed REAL-run PDFs to the configured Paperless GPT auto folder
# ==========================================================

set -o pipefail

SCRIPT_VERSION="v1.2.3"

# ----------------------------------------------------------
# Source / destination configuration
# ----------------------------------------------------------
SOURCE_IP="172.20.30.251"
DEST_IP="172.20.30.250"
SSH_KEY="/boot/config/ssh_keys/id_ed25519_unraid_backup"
KNOWN_HOSTS_FILE="/boot/config/ssh_keys/known_hosts_unraid_backup"

SSH_OPTS=(
    -i "$SSH_KEY"
    -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE"
    -o StrictHostKeyChecking=yes
    -o UpdateHostKeys=no
    -o BatchMode=yes
)

RSYNC_SSH="ssh -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS_FILE -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o BatchMode=yes"

# ----------------------------------------------------------
# Reporting and log configuration
# ----------------------------------------------------------
# Install the helper script at this persistent location on MAIN server.
REPORT_SCRIPT="/boot/config/backup_scripts/weekly_unraid_report_v1.1.0.sh"
REPORT_ROOT="/mnt/user/BackupReports/WeeklyUnraidBackup"
REPORTS_SHARE_NAME="BackupReports"

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_WORK_DIR="/tmp/weekly_unraid_backup_${RUN_ID}"
CHANGES_DIR="$RUN_WORK_DIR/changes"
SHARES_PROCESSED_FILE="$RUN_WORK_DIR/shares_processed.txt"
META_FILE="$RUN_WORK_DIR/run.meta"

LOG_DIR="$REPORT_ROOT/logs"
REPORT_DIR="$REPORT_ROOT/reports"
LOG_FILE="$LOG_DIR/weekly_unraid_backup_${RUN_ID}.log"
REPORT_FILE="$REPORT_DIR/weekly_unraid_backup_report_${RUN_ID}.txt"
REPORT_PDF_FILE="$REPORT_DIR/weekly_unraid_backup_report_${RUN_ID}.pdf"

START_EPOCH="$(date +%s)"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# "yes" generates the successful end-of-run report.
GENERATE_REPORT="yes"
# For testing, default is not to spend time computing/reporting a dry-run.
GENERATE_REPORT_DURING_DRY_RUN="no"
# "yes" calculates per-share current sizes on both servers in the report.
# This is useful, but can add runtime for very large shares.
CALCULATE_SHARE_SIZES="yes"

# ----------------------------------------------------------
# Paperless GPT PDF report ingestion
# ----------------------------------------------------------
# Keeps the TXT and PDF reports in REPORT_DIR; copies only the PDF to Paperless GPT.
COPY_REPORT_PDF_TO_PAPERLESS="yes"

# Correct auto-ingestion location for this environment.
PAPERLESS_CONSUME_DIR="/mnt/user/Paperless/consume/paperless-gpt-auto/BackupReports"

# Import real-backup PDFs only by default.
COPY_DRY_RUN_REPORT_PDF_TO_PAPERLESS="no"

# ----------------------------------------------------------
# Lock and operating mode
# ----------------------------------------------------------
LOCK_DIR="/var/run/weekly_unraid_backup.lockdir"
LOCK_PID_FILE="$LOCK_DIR/pid"
LOCK_ACQUIRED="no"
CLEANUP_DONE="no"

# First validation run should be "yes".
# Set to "no" for the real weekly backup.
DRY_RUN="yes"

# ----------------------------------------------------------
# IPMI/BMC power control using existing IPMI-Tools Docker
# ----------------------------------------------------------
USE_IPMI_POWER_ON="yes"
IPMI_CONTAINER="IPMI-Tools"
BMC_IP="172.20.30.136"
BMC_USER="lugocloud"
BMC_PASS_FILE_IN_CONTAINER="/data/backup_bmc.pass"
IPMI_INTERFACE="lanplus"
IPMI_CIPHER="17"
IPMI_PRIVILEGE="ADMINISTRATOR"

# Backup server boot timing.
IPMI_WAIT_SECONDS="120"
PING_WAIT_ATTEMPTS="180"       # 180 x 10 sec = 30 minutes
PING_WAIT_SECONDS="10"
SSH_WAIT_ATTEMPTS="90"         # 90 x 10 sec = 15 minutes after ping
SSH_WAIT_SECONDS="10"

# ----------------------------------------------------------
# Service handling
# ----------------------------------------------------------
STOP_SOURCE_DOCKER_FOR_CRITICAL="yes"
STOP_SOURCE_LIBVIRT="no"
STOP_DEST_DOCKER="yes"
STOP_DEST_LIBVIRT="no"

SOURCE_DOCKER_DISABLED_BY_SCRIPT="no"
SOURCE_DOCKER_ORIGINAL_SETTING=""
SOURCE_LIBVIRT_STOPPED="no"

# ----------------------------------------------------------
# Backup behavior
# ----------------------------------------------------------
CCTV_SHARE_NAME="CCTVStorage"
CRITICAL_SHARES=("appdata" "system")

mkdir -p "$LOG_DIR" "$REPORT_DIR" "$CHANGES_DIR"
: > "$SHARES_PROCESSED_FILE"
mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
touch "$KNOWN_HOSTS_FILE"
chmod 600 "$KNOWN_HOSTS_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

# ----------------------------------------------------------
# PID-directory lock: avoids inherited file descriptors.
# ----------------------------------------------------------
acquire_lock() {
    local OLD_PID=""

    if [ -d "$LOCK_DIR" ]; then
        [ -f "$LOCK_PID_FILE" ] && OLD_PID="$(cat "$LOCK_PID_FILE" 2>/dev/null)"

        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            log "Another backup script instance is already running with PID $OLD_PID. Exiting."
            return 1
        fi

        log "Removing stale backup PID lock from a previous interrupted run."
        rm -rf "$LOCK_DIR"
    fi

    # Protect against orphaned transfers left by an older script or an interrupted run.
    if pgrep -af "rsync .*${DEST_IP}:/mnt/user/" >/dev/null 2>&1; then
        log "An existing rsync transfer to the backup server is still active. Exiting."
        pgrep -af "rsync .*${DEST_IP}:/mnt/user/" | tee -a "$LOG_FILE"
        return 1
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_PID_FILE"
        LOCK_ACQUIRED="yes"
        return 0
    fi

    log "ERROR: Unable to acquire backup lock."
    return 1
}

release_lock() {
    if [ "$LOCK_ACQUIRED" = "yes" ]; then
        if [ -f "$LOCK_PID_FILE" ] && [ "$(cat "$LOCK_PID_FILE" 2>/dev/null)" = "$$" ]; then
            rm -rf "$LOCK_DIR"
        fi
        LOCK_ACQUIRED="no"
    fi
}

# ----------------------------------------------------------
# Unraid Docker setting control
# ----------------------------------------------------------
get_local_docker_setting() {
    if [ -f /boot/config/docker.cfg ]; then
        awk -F'"' '/^DOCKER_ENABLED=/{print $2; exit}' /boot/config/docker.cfg
    fi
}

set_local_docker_enabled() {
    local VALUE="$1"

    if [ ! -f /boot/config/docker.cfg ]; then
        log "ERROR: /boot/config/docker.cfg not found on main server."
        return 1
    fi

    log "Setting MAIN server Unraid Enable Docker to: $VALUE"
    cp -a /boot/config/docker.cfg /boot/config/docker.cfg.backup-script.bak 2>/dev/null || true

    if grep -q '^DOCKER_ENABLED=' /boot/config/docker.cfg; then
        sed -i "s/^DOCKER_ENABLED=.*/DOCKER_ENABLED=\"$VALUE\"/" /boot/config/docker.cfg
    else
        echo "DOCKER_ENABLED=\"$VALUE\"" >> /boot/config/docker.cfg
    fi

    if [ "$VALUE" = "no" ]; then
        /etc/rc.d/rc.docker stop >/dev/null 2>&1 || true
        for ((i=1; i<=60; i++)); do
            if ! pgrep -x dockerd >/dev/null 2>&1; then
                log "MAIN Docker is stopped."
                return 0
            fi
            sleep 1
        done
        log "ERROR: MAIN Docker did not stop within 60 seconds."
        return 1
    fi

    /etc/rc.d/rc.docker start >/dev/null 2>&1 || true
    for ((i=1; i<=60; i++)); do
        if docker info >/dev/null 2>&1; then
            log "MAIN Docker service is running."
            return 0
        fi
        sleep 1
    done

    log "ERROR: MAIN Docker did not start within 60 seconds."
    return 1
}

restore_source_services() {
    if [ "$SOURCE_DOCKER_DISABLED_BY_SCRIPT" = "yes" ]; then
        if [ "$SOURCE_DOCKER_ORIGINAL_SETTING" = "yes" ]; then
            log "Re-enabling MAIN Docker using the saved original Enable Docker setting."
            set_local_docker_enabled "yes" || log "WARNING: Failed to re-enable MAIN Docker automatically."
        else
            log "MAIN Docker was originally disabled; leaving Enable Docker set to no."
        fi
        SOURCE_DOCKER_DISABLED_BY_SCRIPT="no"
    fi

    if [ "$SOURCE_LIBVIRT_STOPPED" = "yes" ]; then
        if [ -x /etc/rc.d/rc.libvirt ]; then
            log "Restarting MAIN VM service."
            /etc/rc.d/rc.libvirt start || true
        fi
        SOURCE_LIBVIRT_STOPPED="no"
    fi
}

cleanup_on_exit() {
    if [ "$CLEANUP_DONE" = "yes" ]; then
        return
    fi
    CLEANUP_DONE="yes"

    if [ "$DRY_RUN" = "no" ]; then
        restore_source_services
    fi

    release_lock
}

# Acquire lock before installing cleanup traps. A rejected second instance
# must not remove the first instance's lock.
if ! acquire_lock; then
    exit 1
fi

trap cleanup_on_exit EXIT
trap 'log "Signal received. Exiting and restoring local services if needed."; exit 130' INT TERM

set_remote_docker_enabled() {
    local VALUE="$1"
    local STATUS

    log "Setting BACKUP server Unraid Enable Docker to: $VALUE"

    ssh "${SSH_OPTS[@]}" root@"$DEST_IP" "VALUE='$VALUE' bash -s" <<'REMOTE_DOCKER' 2>&1 | tee -a "$LOG_FILE"
if [ ! -f /boot/config/docker.cfg ]; then
    echo "ERROR: /boot/config/docker.cfg not found on backup server."
    exit 1
fi

cp -a /boot/config/docker.cfg /boot/config/docker.cfg.backup-script.bak 2>/dev/null || true

if grep -q '^DOCKER_ENABLED=' /boot/config/docker.cfg; then
    sed -i "s/^DOCKER_ENABLED=.*/DOCKER_ENABLED=\"$VALUE\"/" /boot/config/docker.cfg
else
    echo "DOCKER_ENABLED=\"$VALUE\"" >> /boot/config/docker.cfg
fi

if [ "$VALUE" = "no" ]; then
    /etc/rc.d/rc.docker stop >/dev/null 2>&1 || true
    for i in $(seq 1 60); do
        if ! pgrep -x dockerd >/dev/null 2>&1; then
            echo "BACKUP Docker is stopped."
            exit 0
        fi
        sleep 1
    done
    echo "ERROR: BACKUP Docker did not stop within 60 seconds."
    exit 1
fi

/etc/rc.d/rc.docker start >/dev/null 2>&1 || true
for i in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
        echo "BACKUP Docker service is running."
        exit 0
    fi
    sleep 1
done

echo "ERROR: BACKUP Docker did not start within 60 seconds."
exit 1
REMOTE_DOCKER

    STATUS=${PIPESTATUS[0]}
    return "$STATUS"
}

ipmi_cmd() {
    if ! docker start "$IPMI_CONTAINER" >/dev/null 2>&1; then
        log "ERROR: Could not start $IPMI_CONTAINER. MAIN Docker must be running to issue IPMI commands."
        return 1
    fi

    docker exec "$IPMI_CONTAINER" ipmitool \
        -I "$IPMI_INTERFACE" \
        -C "$IPMI_CIPHER" \
        -L "$IPMI_PRIVILEGE" \
        -H "$BMC_IP" \
        -U "$BMC_USER" \
        -f "$BMC_PASS_FILE_IN_CONTAINER" \
        "$@"
}

prepare_known_hosts() {
    log "Preparing persistent SSH known_hosts file."

    if ssh-keygen -F "$DEST_IP" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1; then
        log "Known host entry already exists for $DEST_IP."
        return 0
    fi

    log "Adding backup server SSH host key to $KNOWN_HOSTS_FILE."

    for ((i=1; i<=SSH_WAIT_ATTEMPTS; i++)); do
        if ssh-keyscan -H "$DEST_IP" >> "$KNOWN_HOSTS_FILE" 2>/dev/null; then
            if ssh-keygen -F "$DEST_IP" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1; then
                log "Known host entry added for $DEST_IP."
                return 0
            fi
        fi
        log "Waiting for SSH host key... attempt $i/$SSH_WAIT_ATTEMPTS"
        sleep "$SSH_WAIT_SECONDS"
    done

    log "ERROR: Could not obtain SSH host key for $DEST_IP."
    return 1
}

record_processed_share() {
    local SHARE_NAME="$1"
    if ! grep -Fxq "$SHARE_NAME" "$SHARES_PROCESSED_FILE" 2>/dev/null; then
        echo "$SHARE_NAME" >> "$SHARES_PROCESSED_FILE"
    fi
}

rsync_share() {
    local SHARE_NAME="$1"
    local SOURCE_PATH="/mnt/user/${SHARE_NAME}/"
    local DEST_PATH="/mnt/user/${SHARE_NAME}/"
    local CHANGE_FILE="$CHANGES_DIR/${SHARE_NAME}.changes"
    local STATUS
    local -a RSYNC_ARGS
    local -a RSYNC_EXCLUDES

    if [ ! -d "$SOURCE_PATH" ]; then
        log "Skipping missing share: $SOURCE_PATH"
        return 0
    fi

    record_processed_share "$SHARE_NAME"
    : > "$CHANGE_FILE"

    RSYNC_ARGS=(
        -avh
        --numeric-ids
        --whole-file
        --omit-dir-times
        --itemize-changes
        --info=progress2,flist2,stats2
        "--out-format=CHANGE|${SHARE_NAME}|%i|%l|%n%L"
    )

    if [ "$DRY_RUN" = "yes" ]; then
        RSYNC_ARGS+=(--dry-run)
    fi

    RSYNC_EXCLUDES=()

    if [ "$SHARE_NAME" = "appdata" ]; then
        RSYNC_EXCLUDES+=("--exclude=**/Cache/***")
        RSYNC_EXCLUDES+=("--exclude=**/cache/***")
        RSYNC_EXCLUDES+=("--exclude=**/tmp/***")
        RSYNC_EXCLUDES+=("--exclude=**/temp/***")
        RSYNC_EXCLUDES+=("--exclude=**/logs/***")
        RSYNC_EXCLUDES+=("--exclude=**/*.sock")
        RSYNC_EXCLUDES+=("--exclude=**/*.pid")
        # Do not copy the BMC credential file stored for the IPMI-Tools container.
        RSYNC_EXCLUDES+=("--exclude=ipmi_tools/backup_bmc.pass")
    fi

    if [ "$SHARE_NAME" = "system" ]; then
        RSYNC_EXCLUDES+=("--exclude=docker/docker.img")
        RSYNC_EXCLUDES+=("--exclude=libvirt/libvirt.img")
    fi

    log "--------------------------------------------------"
    log "Backing up share: $SHARE_NAME"
    log "Source: $SOURCE_PATH"
    log "Destination: root@$DEST_IP:$DEST_PATH"
    log "Delete from backup: NO"
    log "--------------------------------------------------"

    ssh "${SSH_OPTS[@]}" root@"$DEST_IP" "mkdir -p '$DEST_PATH'" 2>&1 | tee -a "$LOG_FILE"
    STATUS=${PIPESTATUS[0]}
    if [ "$STATUS" -ne 0 ]; then
        log "ERROR: Could not create/access destination folder for share $SHARE_NAME."
        return "$STATUS"
    fi

    rsync "${RSYNC_ARGS[@]}" \
        "${RSYNC_EXCLUDES[@]}" \
        -e "$RSYNC_SSH" \
        "$SOURCE_PATH" \
        root@"$DEST_IP":"$DEST_PATH" \
        2>&1 | tee -a "$LOG_FILE" "$CHANGE_FILE"

    STATUS=${PIPESTATUS[0]}

    if [ "$STATUS" -eq 24 ]; then
        log "WARNING: rsync completed for share $SHARE_NAME with code 24; files vanished during transfer. Treating as non-fatal."
        return 0
    fi

    if [ "$STATUS" -ne 0 ]; then
        log "ERROR: rsync failed for share $SHARE_NAME with status $STATUS."
        return "$STATUS"
    fi

    log "Completed backup for share: $SHARE_NAME"
    return 0
}

copy_report_pdf_to_paperless() {
    local PAPERLESS_TARGET_FILE PAPERLESS_TEMP_FILE

    if [ "$COPY_REPORT_PDF_TO_PAPERLESS" != "yes" ]; then
        log "Paperless PDF report copy disabled by configuration."
        return 0
    fi

    if [ "$DRY_RUN" = "yes" ] && [ "$COPY_DRY_RUN_REPORT_PDF_TO_PAPERLESS" != "yes" ]; then
        log "DRY RUN enabled. Paperless PDF report copy skipped by configuration."
        return 0
    fi

    if [ ! -s "$REPORT_PDF_FILE" ]; then
        log "WARNING: Paperless PDF copy skipped; PDF report is missing or empty: $REPORT_PDF_FILE"
        return 1
    fi

    if ! mkdir -p "$PAPERLESS_CONSUME_DIR"; then
        log "WARNING: Could not create Paperless GPT auto-ingestion folder: $PAPERLESS_CONSUME_DIR"
        return 1
    fi

    PAPERLESS_TARGET_FILE="$PAPERLESS_CONSUME_DIR/$(basename "$REPORT_PDF_FILE")"
    PAPERLESS_TEMP_FILE="${PAPERLESS_TARGET_FILE}.part"

    # Copy under an unconsumed temporary extension, then rename after completion.
    rm -f "$PAPERLESS_TEMP_FILE"

    if cp -p "$REPORT_PDF_FILE" "$PAPERLESS_TEMP_FILE" && \
       mv -f "$PAPERLESS_TEMP_FILE" "$PAPERLESS_TARGET_FILE"; then
        log "Copied PDF backup report to Paperless GPT auto-ingestion folder: $PAPERLESS_TARGET_FILE"
        return 0
    fi

    rm -f "$PAPERLESS_TEMP_FILE"
    log "WARNING: Failed to copy PDF report into Paperless GPT auto-ingestion folder."
    return 1
}

generate_success_report() {
    local END_EPOCH END_TIME MODE REPORT_STATUS

    if [ "$GENERATE_REPORT" != "yes" ]; then
        log "Report generation disabled by configuration."
        return 0
    fi

    if [ "$DRY_RUN" = "yes" ] && [ "$GENERATE_REPORT_DURING_DRY_RUN" != "yes" ]; then
        log "DRY RUN enabled. Report generation skipped by configuration."
        return 0
    fi

    if [ ! -r "$REPORT_SCRIPT" ]; then
        log "WARNING: Report helper not found or not readable: $REPORT_SCRIPT"
        return 0
    fi

    # Files stored on Unraid /boot are intentionally non-executable.
    # Invoke the persistent helper through bash instead of requiring chmod +x.
    if ! bash -n "$REPORT_SCRIPT" 2>>"$LOG_FILE"; then
        log "WARNING: Report helper has invalid shell syntax: $REPORT_SCRIPT"
        return 0
    fi

    END_EPOCH="$(date +%s)"
    END_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    if [ "$DRY_RUN" = "yes" ]; then
        MODE="DRY-RUN"
    else
        MODE="REAL"
    fi

    cat > "$META_FILE" <<EOF
SCRIPT_VERSION="$SCRIPT_VERSION"
RUN_ID="$RUN_ID"
MODE="$MODE"
START_EPOCH="$START_EPOCH"
END_EPOCH="$END_EPOCH"
START_TIME="$START_TIME"
END_TIME="$END_TIME"
SOURCE_IP="$SOURCE_IP"
DEST_IP="$DEST_IP"
SSH_KEY="$SSH_KEY"
KNOWN_HOSTS_FILE="$KNOWN_HOSTS_FILE"
CALCULATE_SHARE_SIZES="$CALCULATE_SHARE_SIZES"
EOF

    log "Generating final text backup report: $REPORT_FILE"
    log "Generating final PDF backup report: $REPORT_PDF_FILE"

    bash "$REPORT_SCRIPT" "$META_FILE" "$RUN_WORK_DIR" "$REPORT_FILE" "$REPORT_PDF_FILE" 2>&1 | tee -a "$LOG_FILE"
    REPORT_STATUS=${PIPESTATUS[0]}

    if [ "$REPORT_STATUS" -ne 0 ]; then
        log "WARNING: Backup succeeded, but report generation failed with status $REPORT_STATUS."
    else
        log "Final text backup report saved to: $REPORT_FILE"
        log "Final PDF backup report saved to: $REPORT_PDF_FILE"

        if ! copy_report_pdf_to_paperless; then
            log "WARNING: PDF report was generated, but Paperless GPT auto-ingestion copy was not completed."
        fi
    fi

    return 0
}

log "=================================================="
log "Backup script version: $SCRIPT_VERSION"
log "Run ID: $RUN_ID"
log "Backup started."
log "Source: /mnt/user/"
log "Destination: root@$DEST_IP:/mnt/user/"
log "Dry run: $DRY_RUN"
log "Delete from backup: NO"
log "Excluded share: $CCTV_SHARE_NAME"
log "Excluded local report share: $REPORTS_SHARE_NAME"
log "IPMI power on: $USE_IPMI_POWER_ON"
log "BMC IP: $BMC_IP"
log "Ping wait max: $((PING_WAIT_ATTEMPTS * PING_WAIT_SECONDS / 60)) minutes"
log "SSH/share readiness wait max: $((SSH_WAIT_ATTEMPTS * SSH_WAIT_SECONDS / 60)) minutes"
log "Log file: $LOG_FILE"
log "Text report file: $REPORT_FILE"
log "PDF report file: $REPORT_PDF_FILE"
log "Paperless PDF report copy: $COPY_REPORT_PDF_TO_PAPERLESS"
log "Paperless GPT auto-ingestion folder: $PAPERLESS_CONSUME_DIR"
log "=================================================="

# ----------------------------------------------------------
# Power on backup server using Intel BMC/IPMI
# ----------------------------------------------------------
if [ "$USE_IPMI_POWER_ON" = "yes" ]; then
    if ping -c 1 -W 2 "$DEST_IP" >/dev/null 2>&1; then
        log "Backup server OS is already online. Skipping IPMI power on."
    else
        log "Backup server appears offline. Checking BMC power status."
        ipmi_cmd power status 2>&1 | tee -a "$LOG_FILE" || true

        log "Sending IPMI power on command to backup server."
        ipmi_cmd power on 2>&1 | tee -a "$LOG_FILE"
        STATUS=${PIPESTATUS[0]}
        if [ "$STATUS" -ne 0 ]; then
            log "ERROR: IPMI power on command failed with status $STATUS."
            exit 1
        fi

        log "IPMI power on command sent. Waiting $IPMI_WAIT_SECONDS seconds before ping checks."
        sleep "$IPMI_WAIT_SECONDS"
    fi
fi

# ----------------------------------------------------------
# Wait for destination ping
# ----------------------------------------------------------
log "Checking backup server ping."
BACKUP_PING_ONLINE="no"

for ((i=1; i<=PING_WAIT_ATTEMPTS; i++)); do
    if ping -c 1 -W 2 "$DEST_IP" >/dev/null 2>&1; then
        log "Backup server responds to ping."
        BACKUP_PING_ONLINE="yes"
        break
    fi
    log "Waiting for backup server ping... attempt $i/$PING_WAIT_ATTEMPTS"
    sleep "$PING_WAIT_SECONDS"
done

if [ "$BACKUP_PING_ONLINE" != "yes" ]; then
    log "ERROR: Backup server did not respond to ping within wait limit. Backup aborted."
    exit 1
fi

# ----------------------------------------------------------
# Prepare SSH host-key trust and wait for /mnt/user mount.
# Do not create /mnt/user until it is confirmed as mounted.
# ----------------------------------------------------------
if ! prepare_known_hosts; then
    log "ERROR: known_hosts setup failed. Backup aborted."
    exit 1
fi

log "Waiting for backup server SSH and mounted /mnt/user share filesystem."
BACKUP_SSH_READY="no"

for ((i=1; i<=SSH_WAIT_ATTEMPTS; i++)); do
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 root@"$DEST_IP" \
        "mountpoint -q /mnt/user" >/dev/null 2>&1; then
        log "Backup server SSH is ready and /mnt/user is mounted."
        BACKUP_SSH_READY="yes"
        break
    fi
    log "Waiting for SSH and /mnt/user mount... attempt $i/$SSH_WAIT_ATTEMPTS"
    sleep "$SSH_WAIT_SECONDS"
done

if [ "$BACKUP_SSH_READY" != "yes" ]; then
    log "ERROR: Backup server SSH or mounted /mnt/user was not ready within wait limit. Backup aborted."
    exit 1
fi

# ----------------------------------------------------------
# Disable Docker on backup server during real backup.
# It remains disabled because this is a standby backup server.
# ----------------------------------------------------------
if [ "$DRY_RUN" = "no" ]; then
    log "Preparing backup server."

    if [ "$STOP_DEST_LIBVIRT" = "yes" ]; then
        ssh "${SSH_OPTS[@]}" root@"$DEST_IP" '
            if [ -x /etc/rc.d/rc.libvirt ] && [ -d /run/libvirt ]; then
                echo "Stopping destination VM service."
                /etc/rc.d/rc.libvirt stop || true
            else
                echo "Destination VM service not running. Skipping libvirt stop."
            fi
        ' 2>&1 | tee -a "$LOG_FILE"
    fi

    if [ "$STOP_DEST_DOCKER" = "yes" ]; then
        if ! set_remote_docker_enabled "no"; then
            log "ERROR: Could not disable Docker on backup server. Backup aborted."
            exit 1
        fi
    fi

    ssh "${SSH_OPTS[@]}" root@"$DEST_IP" "sync" 2>&1 | tee -a "$LOG_FILE"
else
    log "DRY RUN enabled. Destination services will not be disabled."
fi

# ----------------------------------------------------------
# Disable MAIN Docker only for appdata/system backup.
# ----------------------------------------------------------
if [ "$DRY_RUN" = "no" ]; then
    log "Preparing main server for critical backup."

    if [ "$STOP_SOURCE_LIBVIRT" = "yes" ]; then
        if [ -x /etc/rc.d/rc.libvirt ] && [ -d /run/libvirt ]; then
            log "Stopping MAIN VM service."
            /etc/rc.d/rc.libvirt stop || true
            SOURCE_LIBVIRT_STOPPED="yes"
        fi
    fi

    if [ "$STOP_SOURCE_DOCKER_FOR_CRITICAL" = "yes" ]; then
        SOURCE_DOCKER_ORIGINAL_SETTING="$(get_local_docker_setting)"
        [ -z "$SOURCE_DOCKER_ORIGINAL_SETTING" ] && SOURCE_DOCKER_ORIGINAL_SETTING="yes"
        log "Original MAIN Enable Docker setting: $SOURCE_DOCKER_ORIGINAL_SETTING"

        if ! set_local_docker_enabled "no"; then
            log "ERROR: Could not disable MAIN Docker. Backup aborted."
            exit 1
        fi
        SOURCE_DOCKER_DISABLED_BY_SCRIPT="yes"
    fi

    sync
else
    log "DRY RUN enabled. MAIN Docker will not be disabled for critical backup."
fi

# ----------------------------------------------------------
# Phase 1: critical shares while MAIN Docker is disabled.
# ----------------------------------------------------------
log "=================================================="
log "PHASE 1: Critical backup started: appdata and system."
log "=================================================="

for SHARE in "${CRITICAL_SHARES[@]}"; do
    if ! rsync_share "$SHARE"; then
        log "ERROR: Critical share backup failed: $SHARE"
        log "Backup server will remain on for inspection."
        exit 1
    fi
done

log "PHASE 1 complete: appdata and system backup completed."

# ----------------------------------------------------------
# Restore MAIN Docker before long, non-critical phase.
# ----------------------------------------------------------
if [ "$DRY_RUN" = "no" ]; then
    restore_source_services
else
    log "DRY RUN enabled. No local Docker restore needed."
fi

# ----------------------------------------------------------
# Phase 2: remaining shares while MAIN Docker is running.
# ----------------------------------------------------------
log "=================================================="
log "PHASE 2: Backing up remaining shares."
log "=================================================="

BACKUP_ERRORS=0
for SHARE_PATH in /mnt/user/*; do
    [ -d "$SHARE_PATH" ] || continue
    SHARE="$(basename "$SHARE_PATH")"

    case "$SHARE" in
        appdata|system)
            log "Skipping already completed critical share: $SHARE"
            continue
            ;;
        "$CCTV_SHARE_NAME")
            log "Skipping excluded CCTV share: $SHARE"
            continue
            ;;
        "$REPORTS_SHARE_NAME")
            log "Skipping local report/log share: $SHARE"
            continue
            ;;
    esac

    if ! rsync_share "$SHARE"; then
        log "WARNING: Backup failed for share: $SHARE"
        BACKUP_ERRORS=$((BACKUP_ERRORS + 1))
    fi
done

if [ "$BACKUP_ERRORS" -ne 0 ]; then
    log "WARNING: Phase 2 completed with $BACKUP_ERRORS error(s)."
    log "Backup server will remain on for inspection."
    exit 1
fi

log "PHASE 2 complete: remaining shares backed up."

# ----------------------------------------------------------
# Backup main server flash configuration. NO DELETE.
# ----------------------------------------------------------
log "Backing up MAIN server flash configuration."

record_processed_share "_flash_config"
FLASH_CHANGE_FILE="$CHANGES_DIR/_flash_config.changes"
: > "$FLASH_CHANGE_FILE"

ssh "${SSH_OPTS[@]}" root@"$DEST_IP" "mkdir -p '/mnt/user/flash-backup-main-server/'" 2>&1 | tee -a "$LOG_FILE"
STATUS=${PIPESTATUS[0]}

if [ "$STATUS" -ne 0 ]; then
    log "WARNING: Could not create flash-config destination folder."
else
    FLASH_ARGS=(
        -avh
        --numeric-ids
        --whole-file
        --omit-dir-times
        --itemize-changes
        --info=progress2,flist2,stats2
        "--out-format=CHANGE|_flash_config|%i|%l|%n%L"
    )

    [ "$DRY_RUN" = "yes" ] && FLASH_ARGS+=(--dry-run)

    rsync "${FLASH_ARGS[@]}" \
        -e "$RSYNC_SSH" \
        /boot/config/ \
        root@"$DEST_IP":/mnt/user/flash-backup-main-server/ \
        2>&1 | tee -a "$LOG_FILE" "$FLASH_CHANGE_FILE"

    STATUS=${PIPESTATUS[0]}

    if [ "$STATUS" -eq 24 ]; then
        log "WARNING: Flash config backup returned code 24; treating as non-fatal."
    elif [ "$STATUS" -ne 0 ]; then
        log "WARNING: Flash config backup failed with status $STATUS; share backup completed."
    else
        log "Flash config backup completed."
    fi
fi

# ----------------------------------------------------------
# Generate final report while destination is still online.
# ----------------------------------------------------------
generate_success_report

# ----------------------------------------------------------
# Clean shutdown of backup server after successful real backup.
# ----------------------------------------------------------
if [ "$DRY_RUN" = "yes" ]; then
    log "DRY RUN enabled. Backup server will NOT be powered off."
    log "Review output, then change DRY_RUN=\"no\" for a real run."
else
    log "Syncing and shutting down backup server cleanly."

    ssh "${SSH_OPTS[@]}" root@"$DEST_IP" "sync && shutdown -h now" 2>&1 | tee -a "$LOG_FILE"
    STATUS=${PIPESTATUS[0]}

    if [ "$STATUS" -eq 0 ]; then
        log "Shutdown command sent successfully."
    else
        log "WARNING: Backup completed, but shutdown command returned status $STATUS."
    fi
fi

log "Backup finished."
log "Backup script version: $SCRIPT_VERSION"
log "=================================================="

exit 0
