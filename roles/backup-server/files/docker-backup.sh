#!/bin/bash
set -euo pipefail
umask 027

START_TS=$(date +%s)

[ $# -ne 1 ] && { echo "Usage: $0 <IP>"; exit 1; }

HOST="$1"
USER="backup_ro"
SSH_KEY="/home/backup_runner/.ssh/backup_rsync"
EXCLUDE_FILE="/etc/backup/$HOST.txt"
RSYNC_EXCLUDES=()

if [ -s "$EXCLUDE_FILE" ]; then
    RSYNC_EXCLUDES+=(--exclude-from="$EXCLUDE_FILE")
fi

REMOTE_PATH="/srv/docker"
BASE="/srv/backups/docker/$HOST"
DATE=$(date +%F-%H%M%S)

LOG="/var/log/docker-backup/docker-backup-$HOST.log"
LOCKFILE="/run/lock/docker-backup-$HOST.lock"
STATUS_FILE="/var/log/docker-backup/status-$HOST"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="$METRICS_DIR/backup-$HOST.prom"

cd /

exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup déjà en cours"; exit 1; }

SOURCE="$USER@$HOST:$REMOTE_PATH/"

mkdir -p "$BASE"
mkdir -p /var/log/docker-backup

echo "=== Backup $HOST started: $(date) ===" >> "$LOG"
echo "[INFO] Target: $HOST" >> "$LOG"
echo "[INFO] Source: $REMOTE_PATH → $BASE" >> "$LOG"

########################################
# LINK-DEST
########################################

if [ -L "$BASE/current" ] && [ -d "$(readlink -f "$BASE/current")" ]; then
    LINK_DEST="--link-dest=$BASE/current"
else
    LINK_DEST=""
fi

########################################
# DATABASE DUMP
########################################

echo "[INFO] Running database backup check" >> "$LOG"

if ! ssh -i "$SSH_KEY" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  "$USER@$HOST" "/usr/local/sbin/db-backup.sh" >> "$LOG" 2>&1
then
    echo "[ERROR] Remote DB backup failed" >> "$LOG"

    umask 022
    cat > "$METRICS_FILE" <<EOF
    backup_status{target="$HOST"} 0
    backup_last_failure{target="$HOST"} $(date +%s)
EOF
umask 027

    exit 1

fi

########################################
# RSYNC
########################################

echo "[INFO] Starting rsync" >> "$LOG"

if sudo rsync -aHAX --delete \
  --numeric-ids \
  -e "ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5" \
  "${RSYNC_EXCLUDES[@]}" \
  $LINK_DEST \
  "$SOURCE" \
  "$BASE/docker-$DATE/" >> "$LOG" 2>&1
then
    echo "[OK] rsync success" >> "$LOG"
else
    echo "[ERROR] rsync failed" >> "$LOG"

    umask 022
    cat > "$METRICS_FILE" <<EOF
    backup_status{target="$HOST"} 0
    backup_last_failure{target="$HOST"} $(date +%s)
EOF
umask 027

    exit 1
fi

########################################
# SNAPSHOT INFO (après rsync)
########################################

echo "[INFO] Snapshot: docker-$DATE" >> "$LOG"

if [ -n "$LINK_DEST" ]; then
    echo "[INFO] link-dest: current" >> "$LOG"
else
    echo "[INFO] Full backup (no previous snapshot)" >> "$LOG"
fi

########################################
# VALIDATION
########################################

if [ ! -d "$BASE/docker-$DATE" ]; then
    echo "[ERROR] Backup directory missing" >> "$LOG"
    exit 1
fi

if [ -z "$(ls -A "$BASE/docker-$DATE")" ]; then
    echo "[ERROR] No files in backup" >> "$LOG"
    exit 1
fi

echo "[INFO] Validation: directory exists and not empty" >> "$LOG"

########################################
# ROTATION
########################################

ln -sfn "$BASE/docker-$DATE" "$BASE/current"

ROTATION_DONE=false

for d in "$BASE"/docker-*; do
    [ -d "$d" ] || continue
    [ "$d" = "$BASE/docker-$DATE" ] && continue

    DATE_DIR=$(basename "$d" | cut -d- -f2-)
    date -d "$DATE_DIR" >/dev/null 2>&1 || continue

    AGE=$(( ( $(date +%s) - $(date -d "$DATE_DIR" +%s) ) / 86400 ))

    if [ "$AGE" -gt 15 ]; then
        echo "[INFO] Rotation: deleting $(basename "$d")" >> "$LOG"
        sudo rm -rf -- "$d"
        ROTATION_DONE=true
    fi
done

if [ "$ROTATION_DONE" = false ]; then
    echo "[INFO] Rotation: nothing to delete" >> "$LOG"
fi

########################################
# STATUS
########################################


echo "[OK] Backup completed" >> "$LOG"

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

echo "OK $(date +%s)" > "$STATUS_FILE"

umask 022
cat > "$METRICS_FILE" <<EOF
backup_status{target="$HOST"} 1
backup_last_success{target="$HOST"} $(date +%s)
backup_duration_seconds{target="$HOST"} $DURATION
EOF
umask 027

echo "[INFO] Duration: ${DURATION}s" >> "$LOG"

echo "=== Backup $HOST completed: $(date) ===" >> "$LOG"

echo "[OK] Backup completed: $HOST"
