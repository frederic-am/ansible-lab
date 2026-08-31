#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SERVICE="$1"
RESTORE_DIR="$2"

SERVICE_DIR="/srv/docker/$SERVICE"
BACKUP_DIR="$RESTORE_DIR/$SERVICE"
DB_BACKUP="$RESTORE_DIR/${SERVICE}-db.sql"
RESTORE_CONF="/etc/backup/restore.conf"

SERVICE_DB_TYPE=""
SERVICE_DB_SERVICE=""
SERVICE_DB_NAME=""
SERVICE_DB_USER=""


log() {
    echo "[INFO] $*"
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

validate_service() {

    [[ -d "$SERVICE_DIR" ]] \
        || die "Service directory '$SERVICE_DIR' not found."
}

validate_restore_directory() {

    [[ -d "$BACKUP_DIR" ]] \
        || die "Restore directory '$BACKUP_DIR' not found."
}

validate_database_backup() {

    [[ "$SERVICE_DB_TYPE" == "none" ]] && return 0

    [[ -f "$DB_BACKUP" ]] \
        || die "Database backup '$DB_BACKUP' not found."
}

load_service_config() {

    while IFS=';' read -r SERVICE_NAME DB_TYPE DB_SERVICE DB_NAME DB_USER; do

        [[ -z "$SERVICE_NAME" || "$SERVICE_NAME" =~ ^# ]] && continue

        [[ "$SERVICE_NAME" != "$SERVICE" ]] && continue

        SERVICE_DB_TYPE="$DB_TYPE"
        SERVICE_DB_SERVICE="$DB_SERVICE"
        SERVICE_DB_NAME="$DB_NAME"
        SERVICE_DB_USER="$DB_USER"

        return 0

    done < "$RESTORE_CONF"

    die "Unknown service '$SERVICE'."
}

stop_containers() {

    log "Stopping containers..."

    docker compose \
        -f "$SERVICE_DIR/docker-compose.yml" \
        down >/dev/null 2>&1
}

restore_files() {

    log "Restoring files..."

    rsync \
        -aHAX \
        --delete \
        --numeric-ids \
        "$BACKUP_DIR/" \
        "$SERVICE_DIR/"
}

start_database() {

    [[ "$SERVICE_DB_TYPE" == "none" ]] && return 0

    log "Starting database..."

    docker compose \
        -f "$SERVICE_DIR/docker-compose.yml" \
        up -d "$SERVICE_DB_SERVICE" >/dev/null 2>&1
}

wait_database() {

    [[ "$SERVICE_DB_TYPE" == "none" ]] && return 0

    log "Waiting for database..."

    for i in {1..30}; do

        if docker compose \
            -f "$SERVICE_DIR/docker-compose.yml" \
            exec -T "$SERVICE_DB_SERVICE" \
            env PGPASSWORD="$SERVICE_DB_USER" \
            psql \
                -U "$SERVICE_DB_USER" \
                -d "$SERVICE_DB_NAME" \
                -c "SELECT 1;" \
                >/dev/null 2>&1
        then
            log "Database is ready."
            return 0
        fi

        sleep 1
    done

    die "Database did not become ready."
}

restore_database() {

    [[ "$SERVICE_DB_TYPE" == "none" ]] && return 0

    start_database
    wait_database

    log "Restoring database..."

    sleep 2

    docker compose \
        -f "$SERVICE_DIR/docker-compose.yml" \
        exec -T "$SERVICE_DB_SERVICE" \
        env PGPASSWORD="$SERVICE_DB_USER" \
        psql \
	    -v ON_ERROR_STOP=1 \
            -U "$SERVICE_DB_USER" \
            -d "$SERVICE_DB_NAME" \
        < "$DB_BACKUP" \
	>/dev/null 2>&1
    
    log "Database restored."
}

start_containers() {

    log "Starting containers..."

    docker compose \
        -f "$SERVICE_DIR/docker-compose.yml" \
        up -d >/dev/null 2>&1
}

wait_services() {

    log "Checking containers..."

    docker compose \
        -f "$SERVICE_DIR/docker-compose.yml" \
        ps --status running
}

cleanup() {

    log "Cleaning temporary restore directory..."

    rm -rf "$RESTORE_DIR"
}

main() {

    validate_service
    validate_restore_directory
    load_service_config
    validate_database_backup
    

    stop_containers
    restore_files
    restore_database
    start_containers
    wait_services
    cleanup

    log "Restore completed."
}

main

