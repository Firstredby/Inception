#!/bin/bash

DB_PASSWORD=$(cat /run/secrets/db_password)
WP_PASSWORD=$(cat /run/secrets/wp_admin_password)
WP_USER_PASSWORD=$(cat /run/secrets/wp_user_password)

mkdir -p /run/php
chown www-data:www-data /run/php
cd /var/www/html

if [ ! -d "/var/www/html/wp-admin" ]; then
    wp --allow-root core download
fi

if [ ! -f wp-config.php ]; then

until mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1
do
    echo "Waiting for MariaDB..."
    sleep 2
done

wp --allow-root config create \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASSWORD" \
    --dbhost="$DB_HOST"

wp --allow-root core install \
    --url=https://ishchyro.42.fr \
    --title="Inception" \
    --admin_user="$WP_ADMIN" \
    --admin_password="$WP_PASSWORD" \
    --admin_email="$WP_EMAIL"

wp --allow-root user create \
    "$WP_USER" \
    "$WP_USER_EMAIL" \
    --user_pass="$WP_USER_PASSWORD" \
    --role=author
fi

exec php-fpm7.4 -F