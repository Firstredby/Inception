#!/bin/bash
set -e

INFO="\033[1;36m"
OK="\033[1;32m"
ERR="\033[1;31m"
RST="\033[0m"

info()    { echo -e "${INFO}[MariaDB]${RST} $1"; }
success() { echo -e "${OK}[ OK ]${RST} $1"; }
failure() { echo -e "${ERR}[FAIL]${RST} $1" >&2; exit 1; }

RUNTIME="/run/mysqld"
DATADIR="/var/lib/mysql"
SOCKET="${RUNTIME}/mysqld.sock"
SECRET="/run/secrets/db_password"

STARTUP_TIMEOUT=30

#
# Configuration
#
[ -s "$SECRET" ]         || failure "Secret ${SECRET} is missing or empty."
[ -n "$MYSQL_DATABASE" ] || failure "MYSQL_DATABASE is not set."
[ -n "$MYSQL_USER" ]     || failure "MYSQL_USER is not set."

MYSQL_PASSWORD=$(cat "$SECRET")

info "Preparing runtime..."

mkdir -p "$RUNTIME"
chown -R mysql:mysql "$RUNTIME"
chown -R mysql:mysql "$DATADIR"

#
# First init
#
if [ ! -d "${DATADIR}/${MYSQL_DATABASE}" ]; then
    info "First launch detected."

    info "Starting temporary MariaDB..."

    mariadbd \
        --user=mysql \
        --skip-networking \
        --socket="$SOCKET" \
        >/dev/null 2>&1 &
    PID=$!

    ready=0
    for _ in $(seq 1 "$STARTUP_TIMEOUT"); do
        if mariadb -u root --socket="$SOCKET" -e "SELECT 1;" >/dev/null 2>&1; then
            ready=1
            break
        fi
        kill -0 "$PID" 2>/dev/null \
            || failure "Temporary server exited during startup."
        sleep 1
    done

    [ "$ready" -eq 1 ] \
        || failure "Temporary server was not ready within ${STARTUP_TIMEOUT}s."

    success "Temporary server is ready."

    info "Creating database..."

    if ! mariadb -u root --socket="$SOCKET" <<EOF
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF
    then
        failure "Could not create database '${MYSQL_DATABASE}' or user '${MYSQL_USER}'."
    fi

    success "Database created."

    info "Stopping temporary server..."

    mariadb-admin -u root --socket="$SOCKET" shutdown >/dev/null 2>&1 \
        || failure "Temporary server refused to shut down."

    wait "$PID" || failure "Temporary server did not stop cleanly."

    success "Initialization complete."

else
    info "Existing database detected. Skipping initialization."
fi

info "Launching MariaDB..."

exec mariadbd --user=mysql 2> >(grep -v '\[Note\]' >&2)