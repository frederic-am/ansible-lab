#!/bin/bash
set -euo pipefail

BACKUP_DIR="/srv/docker/backups"
CONFIG_FILE="/etc/backup/db-backup.conf"

mkdir -p "$BACKUP_DIR"
rm -f "$BACKUP_DIR"/*.sql

[ -f "$CONFIG_FILE" ] || {
    echo "Missing config file"
    exit 1
}

########################################
# LOOP CONFIG
########################################

DB_COUNT=0

while IFS=";" read -r NAME TYPE DATABASE USER PASS_ENV; do

    # Ignore comments and empty lines
    [[ -z "$NAME" || "$NAME" =~ ^# ]] && continue

    DB_COUNT=$((DB_COUNT + 1))

    if ! docker ps --format '{{.Names}}' | grep -qw "$NAME"; then
        echo "[INFO] $NAME not running, skip"
        continue
    fi

    echo "[INFO] Backup $NAME ($TYPE)"

    case "$TYPE" in

        mariadb)

            PASSWORD=$(docker exec "$NAME" printenv "$PASS_ENV")

            # Wait until MariaDB is ready
            for i in {1..10}; do
                if docker exec "$NAME" \
                    mysqladmin ping \
                    -u "$USER" \
                    -p"$PASSWORD" \
                    --silent >/dev/null 2>&1
                then
                    break
                fi
                sleep 2
            done

            docker exec "$NAME" \
                mysqldump \
                    -u "$USER" \
                    -p"$PASSWORD" \
                    --single-transaction \
                    --quick \
                    --routines \
                    --events \
                    "$DATABASE" \
            > "$BACKUP_DIR/${NAME}.sql"
            ;;

        postgres)

            docker exec "$NAME" \
                pg_dump \
                    -U "$USER" \
                    -d "$DATABASE" \
                    --clean \
                    --if-exists \
            > "$BACKUP_DIR/${NAME}.sql"
            ;;

        *)

            echo "[ERROR] Unknown type: $TYPE"
            exit 1
            ;;

    esac

done < "$CONFIG_FILE"

########################################
# VALIDATION
########################################

shopt -s nullglob

files=("$BACKUP_DIR"/*.sql)

if [ ${#files[@]} -eq 0 ]; then

    if [ "$DB_COUNT" -eq 0 ]; then
        echo "[INFO] No database configured"
        exit 0
    fi

    echo "[ERROR] No database dumps created"
    exit 1
fi

for f in "${files[@]}"; do
    [ -s "$f" ] || {
        echo "Empty dump: $f"
        exit 1
    }
done

########################################
# PERMISSIONS
########################################

chmod 750 "$BACKUP_DIR"
chmod 640 "$BACKUP_DIR"/*.sql

