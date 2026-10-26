#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

#
# Configuration
#

SSH_USER="backup_admin"
SSH_KEY="/home/backup_admin/.ssh/backup_restore"
RESTORE_DIR="/var/tmp/restore-$(date +%Y%m%d-%H%M%S)"
RESTORE_CONFIG_DIR="/etc/backup/restore"

#
# Logging
#

usage() {
    cat <<EOF
Usage:
    $SCRIPT_NAME <target> <service> <snapshot>

Example:
    $SCRIPT_NAME vm-app-01 gitea docker-2026-07-21-111838
EOF
}

log() {
    echo "[INFO] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

#
# Validation
#

validate_target() {

    local target="$1"

    BACKUP_ROOT="/srv/backups/docker/$target"

    [[ -d "$BACKUP_ROOT" ]] \
        || die "Unknown target '$target'."
}

validate_service() {

    local service="$1"

    [[ -d "$BACKUP_ROOT/$SNAPSHOT/$service" ]] \
        || die "Service '$service' not found in snapshot '$SNAPSHOT'."
}

validate_snapshot() {

    local snapshot="$1"

    [[ -d "$BACKUP_ROOT/$snapshot" ]] \
        || die "Snapshot '$snapshot' not found."
}

load_service_config() {

    local config="$RESTORE_CONFIG_DIR/$TARGET.conf"
    local name db_type db_container compose_service database user

    [[ -f "$config" ]] \
        || die "Restore configuration not found: $config"

    while IFS=';' read -r name db_type db_container compose_service database user; do
        [[ -z "$name" || "$name" =~ ^# ]] && continue
        [[ "$name" != "$SERVICE" ]] && continue

        [[ "$db_container" == "ERROR_DB_MAPPING" ]] \
            && die "Invalid database mapping for service '$SERVICE'."

        SERVICE_DB_TYPE="$db_type"
        SERVICE_DB_CONTAINER="$db_container"

        if [[ "$SERVICE_DB_TYPE" != "none" ]]; then
            [[ -n "$SERVICE_DB_CONTAINER" ]] \
                || die "Database container not configured for '$SERVICE'."
        fi

        return 0
    done < "$config"

    die "Service '$SERVICE' not found in $config."
}

validate_database_backup() {

    [[ "$SERVICE_DB_TYPE" == "none" ]] && return 0

    local dump="$BACKUP_ROOT/$SNAPSHOT/backups/${SERVICE_DB_CONTAINER}.sql"

    [[ -f "$dump" ]] \
        || die "Database dump not found: $dump"
}

validate_remote_access() {

    log "Checking SSH access..."

    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$SSH_USER@$TARGET" \
        true \
        || die "SSH connection failed."
}

validate_remote_restore_script() {

    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$SSH_USER@$TARGET" \
        "test -x /usr/local/sbin/docker-restore.sh" \
        || die "Remote restore script not found."
}

validate_remote_sudo() {

    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$SSH_USER@$TARGET" \
        "sudo -n -l /usr/local/sbin/docker-restore.sh >/dev/null" \
        || die "Remote sudo permission denied."
}

prepare_restore_directory() {

    log "Preparing remote restore directory..."

    ssh \
        -i "$SSH_KEY" \
        -o BatchMode=yes \
        "$SSH_USER@$TARGET" \
        "mkdir -p '$RESTORE_DIR'" \
        || die "Unable to prepare restore directory."
}

copy_restore_files() {

    log "Copying service files..."

    sudo rsync \
        -aHAX \
        --delete \
        --numeric-ids \
        --rsync-path="sudo rsync" \
        -e "ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5" \
        "$BACKUP_ROOT/$SNAPSHOT/$SERVICE/" \
        "$SSH_USER@$TARGET:$RESTORE_DIR/$SERVICE/" \
        || die "Unable to copy service files."

    if [[ "$SERVICE_DB_TYPE" != "none" ]]; then
        local dump="$BACKUP_ROOT/$SNAPSHOT/backups/${SERVICE_DB_CONTAINER}.sql"

        [[ -f "$dump" ]] \
            || die "Database dump not found: $dump"

        log "Copying database dump..."

        scp \
            -i "$SSH_KEY" \
            "$dump" \
            "$SSH_USER@$TARGET:$RESTORE_DIR/" \
            || die "Unable to copy database dump."
    fi
}

#
# Main
#

[[ $# -eq 3 ]] || {
    usage
    exit 1
}

TARGET="$1"
SERVICE="$2"
SNAPSHOT="$3"

validate_target "$TARGET"
validate_snapshot "$SNAPSHOT"
validate_service "$SERVICE"
load_service_config
validate_database_backup

validate_remote_access
validate_remote_restore_script
validate_remote_sudo

echo
echo "----------------------------------------"
echo "Restore summary"
echo "----------------------------------------"
echo "Target   : $TARGET"
echo "Service  : $SERVICE"
echo "Snapshot : $SNAPSHOT"
echo "----------------------------------------"
echo

read -rp "Type YES to continue: " answer

[[ "$answer" == "YES" ]] || {
    echo "Restore cancelled."
    exit 0
}

prepare_restore_directory
copy_restore_files

log "Starting restore..."
log "Temporary directory: $RESTORE_DIR"

if ! ssh \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    "$SSH_USER@$TARGET" \
    "sudo /usr/local/sbin/docker-restore.sh '$SERVICE' '$RESTORE_DIR'"
then
    die "Restore failed."
fi

exit 0

