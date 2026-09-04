#!/bin/bash
set -e

INFO="\033[1;36m"
OK="\033[1;32m"
ERR="\033[1;31m"
RST="\033[0m"

info()    { echo -e "${INFO}[MariaDB]${RST} $1"; }
success() { echo -e "${OK}[ OK ]${RST} $1"; }
failure() { echo -e "${ERR}[FAIL]${RST} $1"; exit 1; }

RUNTIME="/run/mysqld"
DATADIR="/var/lib/mysql"

MYSQL_PASSWORD=$(cat /run/secrets/db_password)

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
        --socket="${RUNTIME}/mysqld.sock" \
        >/dev/null 2>&1 &
    PID=$!

    until mariadb -u root \
        --socket="${RUNTIME}/mysqld.sock" \
        -e "SELECT 1;" >/dev/null 2>&1
    do
        sleep 1
    done

    success "Temporary server is ready."

    info "Creating database..."

    mariadb -u root \
        --socket="${RUNTIME}/mysqld.sock" <<EOF
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF

    success "Database created."

    info "Stopping temporary server..."

    mariadb-admin \
        -u root \
        --socket="${RUNTIME}/mysqld.sock" \
        shutdown >/dev/null 2>&1

    wait "$PID"

    success "Initialization complete."

else
    info "Existing database detected. Skipping initialization."
fi

info "Launching MariaDB..."

exec mariadbd --user=mysql 2> >(grep -v '\[Note\]' >&2)