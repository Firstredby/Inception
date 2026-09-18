# Developer documentation

This document covers setting the project up from nothing, building and running it, managing the containers and volumes, and knowing where the data lives. For using the site once it runs, see [USER_DOC.md](USER_DOC.md).

---

## 1. Prerequisites

| Requirement | Check | Note |
|---|---|---|
| Docker Engine | `docker --version` | The daemon must be running |
| Compose V2 plugin | `docker compose version` | The `Makefile` calls `docker compose`, not `docker-compose` |
| GNU Make | `make --version` | |
| `sudo` rights | | Needed for the `/etc/hosts` entry and for the ownership fix in `make clean` |

If `docker compose version` fails but `docker-compose --version` works, you have the old standalone V1 binary. Either install the plugin, or change the first line of the `Makefile`:

```make
COMPOSE = docker-compose -f srcs/docker-compose.yml
```

Your user must be able to reach the Docker daemon without `sudo`:

```bash
sudo usermod -aG docker $USER   # log out and back in afterwards
```

---

## 2. Repository layout

```
.
├── Makefile                       # entry point for every operation
├── .gitignore                     # excludes secrets/ and .env
├── README.md
├── USER_DOC.md
├── DEV_DOC.md
├── secrets/                       # NOT in git — you create it
│   ├── db_password.txt
│   ├── wp_admin_password.txt
│   └── wp_user_password.txt
└── srcs/
    ├── .env.example               # template
    ├── .env                       # NOT in git — you create it
    ├── docker-compose.yml         # services, network, volumes, secrets
    └── requirements/
        ├── nginx/
        │   ├── dockerfile
        │   ├── conf/nginx.conf
        │   └── tools/create_cert.sh
        ├── wordpress/
        │   ├── dockerfile
        │   └── tools/init.sh
        └── mariadb/
            ├── dockerfile
            ├── config/50-server.cnf   # kept for reference; not copied into the image
            └── tools/setup.sh
```

Two things are absent from a fresh clone and must be created by hand: `secrets/` with its three files, and `srcs/.env`. Sections 4 and 5 cover both.

---

## 3. Setting up from scratch

### Clone

```bash
git clone https://github.com/Firstredby/Inception.git
cd Inception
```

### Point the domain at the machine

nginx serves exactly one virtual host, `ishchyro.42.fr`, and the certificate is issued for that name. Without this entry the site is unreachable:

```bash
echo "127.0.0.1 ishchyro.42.fr" | sudo tee -a /etc/hosts
```

Verify with `ping -c1 ishchyro.42.fr`.

If you fork the project under a different login, the domain appears in three places and all three must agree:

| File | What to change |
|---|---|
| `srcs/requirements/nginx/conf/nginx.conf` | `server_name` |
| `srcs/requirements/nginx/tools/create_cert.sh` | `-subj "/CN=..."` |
| `srcs/requirements/wordpress/tools/init.sh` | `--url=https://...` |

---

## 4. The environment file

`docker compose` loads `srcs/.env` automatically, because the compose file lives in `srcs/`. There is no `--env-file` flag anywhere; the location is what makes it work.

```bash
cp srcs/.env.example srcs/.env
```

| Variable | Read by | Meaning |
|---|---|---|
| `MYSQL_DATABASE` | mariadb | Database created on first launch |
| `MYSQL_USER` | mariadb | Application user created on first launch |
| `DB_NAME` | wordpress | **Must equal `MYSQL_DATABASE`** |
| `DB_USER` | wordpress | **Must equal `MYSQL_USER`** |
| `DB_HOST` | wordpress | Service name of the database — `mariadb` |
| `WP_ADMIN` | wordpress | Administrator login. Must **not** contain `admin` or `administrator` — the subject forbids it |
| `WP_EMAIL` | wordpress | Administrator email |
| `WP_USER` | wordpress | Second user, created with the `author` role |
| `WP_USER_EMAIL` | wordpress | Second user's email |

A working example:

```ini
MYSQL_DATABASE=wordpress
MYSQL_USER=wpuser

DB_NAME=wordpress
DB_USER=wpuser
DB_HOST=mariadb

WP_ADMIN=bossman
WP_EMAIL=bossman@student.42.fr

WP_USER=ishchyro
WP_USER_EMAIL=ishchyro@student.42.fr
```

The database name and user are duplicated on purpose: MariaDB creates them, WordPress connects with them, and the two services read their own variables independently. `DB_HOST` is the one value that is not free — it has to be `mariadb`, the service name in `docker-compose.yml`, because that is what Docker's embedded DNS resolves on the `inception` network.

`$USER` is used by both the compose file (`/home/${USER}/data/...`) and the `Makefile`, but it comes from your shell, not from `.env`. Do not set it there.

### The `check-env` guard

Getting these wrong produces a symptom that is slow to diagnose: the WordPress container sits in its readiness loop printing `Waiting for MariaDB...`, nginx answers `502`, and none of the three containers logs anything that names the cause, because `init.sh` silences the connection attempt. `make all` therefore depends on a `check-env` target that runs before the first `docker` command.

It performs three passes and reports everything it finds in each, rather than one failure per run:

1. **The file.** If `srcs/.env` is absent it says so and suggests copying the template.
2. **Presence.** Every name in `ENV_VARS` must resolve to a non-empty value. Missing and empty are treated alike. Copying `.env.example` without filling it in produces a list of eight.
3. **Consistency.** `DB_NAME` must equal `MYSQL_DATABASE`; `DB_USER` must equal `MYSQL_USER`; `DB_HOST` must be exactly `mariadb`; and `WP_ADMIN` must not contain `admin`, tested case-insensitively, since the subject forbids it and an evaluator will check.

```
ERROR: DB_NAME must match MYSQL_DATABASE.
ERROR: DB_USER must match MYSQL_USER.
ERROR: DB_HOST must be 'mariadb' - the compose service name.

Aborting.
```

Values are read with a small `get()` helper defined inside the recipe, which greps the assignment, takes the last occurrence and strips whitespace. It does **not** strip trailing comments, so `DB_HOST=mariadb # note` would fail the comparison. Put comments on their own line, as `.env.example` does.

To run either guard without building:

```bash
make check-env
make check-secrets
```

---

## 5. Secrets

Passwords are delivered as Docker secrets: files on the host, mounted read-only into the containers that declare them, at `/run/secrets/<name>`. They are never environment variables, which would put them in `docker inspect` output and in the environment of every child process.

```bash
mkdir -p secrets
echo 'db_pass_here'       > secrets/db_password.txt
echo 'wp_admin_pass_here' > secrets/wp_admin_password.txt
echo 'wp_user_pass_here'  > secrets/wp_user_password.txt
chmod 600 secrets/*.txt
```

The trailing newline `echo` leaves is harmless: the entrypoints read the files with `MYSQL_PASSWORD=$(cat /run/secrets/db_password)`, and command substitution strips trailing newlines. One password per file, nothing else in it.

Which service gets which:

| Secret | mariadb | wordpress |
|---|:---:|:---:|
| `db_password` | ✓ | ✓ |
| `wp_admin_password` | | ✓ |
| `wp_user_password` | | ✓ |

`make` runs a `check-secrets` target before anything else. It tests each file with `[ -s ]`, so a file that is missing **and** a file that exists but is empty both count as a failure; it prints the offending paths and aborts with a non-zero status, which stops the rest of `make all` from running:

```
ERROR: required secret files are missing:

  secrets/db_password.txt
  secrets/wp_admin_password.txt

Create each one with:  echo 'password' > <file>
Aborting.
```

> **There is deliberately no root secret.** `setup.sh` connects as root four times, all during first-run initialization, and never passes a password. It does not need one: Debian's `mariadb-server` package configures `root@localhost` with the `unix_socket` authentication plugin, which authenticates on the system UID of the connecting process instead of a password. Root is therefore usable only by the `root` user from a shell inside the container, and is unreachable over the network regardless of what the network configuration says. Adding a root password secret would have meant either shipping a file nothing reads, or replacing socket authentication with password authentication and making the account *more* reachable, not less. Every root command in this document connects **without** `-p` for this reason.

---

## 6. Data directories

The two volumes are bind mounts, so the host directories must exist *before* Compose starts — Docker will not create them and the stack fails outright if they are absent. `make all` creates them for you:

```bash
mkdir -p /home/$USER/data/mariadb /home/$USER/data/wordpress
```

---

## 7. Building and launching

```bash
make
```

The first build takes a few minutes: three Debian images, `apt` installs, the WordPress tarball and wp-cli download. Later builds reuse layers and are fast.

### Make targets

| Target | What it runs | Effect |
|---|---|---|
| `make` / `make all` | `check-secrets`, `check-env`, `mkdir`, `up -d --build` | Validates configuration, creates data directories, builds and starts detached |
| `make up` | `up` | Foreground, logs on stdout |
| `make down` | `down` | Stops and removes containers; data survives |
| `make logs` | `logs` | Dumps logs from all services |
| `make check-secrets` | — | Runs the secrets guard on its own |
| `make check-env` | — | Runs the environment guard on its own |
| `make clean` | `down` + `docker rm -f` / `rmi -f` on everything | Removes **all** containers and images on the host, then `chown`s the data directory back to you |
| `make fclean` | `clean` + `rm -rf /home/$USER/data` | Destroys the database and the site |
| `make re` | `fclean` + `all` | Full rebuild on an empty site |

> `clean` deliberately removes every container and image on the machine, not just this project's. Convenient inside the 42 VM, destructive anywhere else.

### Working with Compose directly

The `Makefile` is a thin wrapper. Anything it does can be done by hand, and for debugging a single service that is usually what you want:

```bash
COMPOSE="docker compose -f srcs/docker-compose.yml"

$COMPOSE up -d --build          # what `make` does
$COMPOSE ps                     # status of the three services
$COMPOSE build --no-cache nginx # rebuild one image, ignoring the layer cache
$COMPOSE up -d --build nginx    # rebuild and restart one service
$COMPOSE restart wordpress      # restart without rebuilding
$COMPOSE stop mariadb           # stop one service
$COMPOSE logs -f wordpress      # follow one service's logs
$COMPOSE config                 # print the fully resolved compose file
```

`$COMPOSE config` is the fastest way to check that `.env` is being picked up: every `${VAR}` should be substituted in the output. If they come out empty, the file is missing or in the wrong place.

---

## 8. Managing containers

```bash
docker ps                       # running containers
docker ps -a                    # including stopped ones
docker inspect nginx            # full configuration of one container
docker stats                    # live CPU and memory use
```

### Getting a shell inside a container

```bash
docker exec -it wordpress bash
docker exec -it mariadb bash
docker exec -it nginx bash
```

### Useful things to run once inside

```bash
# WordPress — wp-cli is installed; --allow-root is required as the entrypoint runs as root
docker exec -it wordpress wp --allow-root core version
docker exec -it wordpress wp --allow-root user list
docker exec -it wordpress wp --allow-root plugin list

# MariaDB — root needs no password from inside the container (unix_socket auth)
docker exec -it mariadb mariadb -u root
docker exec -it mariadb mariadb -u root -e "SHOW DATABASES;"
docker exec -it mariadb mariadb -u root -e "SELECT User, Host, plugin FROM mysql.user;"

# As the application user, with the password from the secret
docker exec -it mariadb sh -c 'mariadb -u "$MYSQL_USER" -p"$(cat /run/secrets/db_password)" "$MYSQL_DATABASE"'

# nginx — validate the config without restarting
docker exec -it nginx nginx -t
docker exec -it nginx openssl x509 -in /etc/nginx/ssl/inception.crt -noout -text
```

### Inspecting the network

```bash
docker network ls
docker network inspect srcs_inception
```

The last command lists the three containers and their addresses on the bridge. To confirm that service-name DNS is working:

```bash
docker exec -it wordpress getent hosts mariadb
docker exec -it nginx getent hosts wordpress
```

Compose prefixes the network name with the project name, which defaults to the directory holding the compose file — hence `srcs_inception`.

---

## 9. Volumes and data persistence

### Where the data lives

| Volume | Host path | Mounted into | Contents |
|---|---|---|---|
| `mariadb` | `/home/$USER/data/mariadb` | `mariadb:/var/lib/mysql` | The database files |
| `wordpress` | `/home/$USER/data/wordpress` | `wordpress:/var/www/html` and `nginx:/var/www/html` | The WordPress installation: core, themes, plugins, uploads, `wp-config.php` |

Both are declared as named volumes but are really bind mounts:

```yaml
volumes:
  mariadb:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/${USER}/data/mariadb
```

`type: none` with `o: bind` tells the `local` driver to bind an existing host directory instead of allocating storage of its own. The service definitions address them by name, while the bytes sit at a path the subject specifies.

The WordPress volume is mounted into two containers at the same path on purpose: php-fpm executes the PHP, and nginx must read the same tree to serve static assets and to compute a `SCRIPT_FILENAME` that php-fpm can actually open.

### What survives what

| Action | Database | Site files |
|---|---|---|
| `make down` | survives | survives |
| `docker rm -f <container>` | survives | survives |
| `make clean` | survives | survives |
| `make fclean` | **destroyed** | **destroyed** |
| `rm -rf /home/$USER/data` | **destroyed** | **destroyed** |

### Volume commands

```bash
docker volume ls
docker volume inspect srcs_mariadb
du -sh /home/$USER/data/*
```

Because these are bind mounts, you can also just look at the host directories directly — `ls /home/$USER/data/wordpress` shows the WordPress tree.

### Backup and restore

```bash
# Database dump — root authenticates by socket, so no password is passed
docker exec mariadb mariadb-dump -u root --all-databases > backup.sql
# on older MariaDB builds the binary is called mysqldump instead

# Site files
tar czf wordpress-backup.tar.gz -C /home/$USER/data wordpress

# Restore the database into a running stack
docker exec -i mariadb mariadb -u root < backup.sql
```

### Permissions

The containers write as `mysql` and `www-data`, so files under `/home/$USER/data` end up owned by those UIDs and your host user may not be able to delete them. `make clean` runs `sudo chown -R $USER:$USER` on the data directory for exactly this reason. If you hit a permission error outside of `make`, run that `chown` by hand.

### Where the initial content actually comes from

Both host directories are empty on a first launch, yet the containers find a populated WordPress tree and an initialized MariaDB datadir. That is not the entrypoint scripts doing it — it is Docker.

When a container mounts a **named volume** that is empty, Docker copies whatever the image already has at that path into the volume before the container starts. This is what makes `type: none` + `o: bind` meaningfully different from a plain bind mount (`-v /host:/container`), which performs no such copy and would simply hide the image's contents. Declaring these as named volumes rather than raw bind mounts is therefore load-bearing, not cosmetic.

So on first launch:

- `/var/www/html` is filled from the WordPress tarball that the `dockerfile` unpacked at build time.
- `/var/lib/mysql` is filled from the datadir that Debian's `mariadb-server` package initialized during `apt install` — which is where `root@localhost` and its `unix_socket` authentication come from.

This is confirmed by the logs. `init.sh` runs `wp core download` *before* it waits for the database, and on a clean `make fclean && make` the first line of `docker logs wordpress` is already `Waiting for MariaDB...` — the download printed nothing because `/var/www/html/wp-admin` was there before the script started.

The `wp core download` guard is therefore a fallback, not the normal path. It matters if the host directory is left non-empty, since Docker only copies into a volume it considers empty.

---

## 10. How the stack works

### Request flow

```
browser ──443/TLS──> nginx ──FastCGI, wordpress:9000──> php-fpm ──3306──> mariadb
```

1. The browser resolves `ishchyro.42.fr` to `127.0.0.1` via `/etc/hosts` and opens a TLS connection on 443.
2. nginx terminates TLS. Static files come straight from `/var/www/html`; anything matching `location ~ \.php$` goes over FastCGI to `wordpress:9000`. The `try_files $uri $uri/ /index.php?$args` rule is what makes permalinks work — any URL that is not a real file is handed to `index.php`.
3. php-fpm executes the PHP.
4. WordPress connects to `mariadb:3306` with the credentials written into `wp-config.php` at install time.

### The network

One user-defined bridge, `inception`. Unlike the default bridge, a user-defined network gets Docker's embedded DNS, so containers resolve each other by service name — which is why `DB_HOST=mariadb` and `fastcgi_pass wordpress:9000` need no hardcoded addresses and survive a container getting a new IP.

Only nginx publishes a port. MariaDB and php-fpm are reachable from inside `inception` and from nowhere else; no firewall rule is involved, because the ports were never published. MariaDB is nevertheless configured with `bind-address = 0.0.0.0` — patched with `sed` in its dockerfile — because it must accept connections from another container, not just from its own loopback. The network boundary, not the bind address, is what keeps it private.

### The three entrypoints

**nginx.** The dockerfile installs nginx and openssl, copies the config, and runs `create_cert.sh` at *build* time to generate a 2048-bit RSA self-signed certificate with `CN=ishchyro.42.fr`, valid a year. `CMD ["nginx", "-g", "daemon off;"]` keeps nginx in the foreground. TLSv1.2 and TLSv1.3 only.

**wordpress.** The dockerfile installs the unversioned `php`, `php-fpm` and `php-mysql` packages — so the PHP version is whatever the base release ships, 8.2 on bookworm — plus `curl` and `mariadb-client`. It then downloads WordPress and wp-cli, replaces the default Unix socket with `listen = 9000` (nginx talks to php-fpm over TCP across the container boundary), and symlinks `sendmail` to `/bin/true` to silence wp-cli's mail errors. The `sed` that sets the port targets `/etc/php/*/fpm/pool.d/www.conf` through a glob rather than a fixed version directory.

`ENTRYPOINT ["/init.sh"]` runs the script in JSON exec form, so no shell sits between Docker and it. At run time `init.sh` reads its three secrets, creates `/run/php` for `www-data`, downloads WordPress only if `/var/www/html/wp-admin` is absent (normally it is not — see section 9), blocks until `mariadb -h "$DB_HOST" ... -e "SELECT 1;"` succeeds, then runs `wp config create`, `wp core install` and `wp user create`. The install block is guarded by `if [ ! -f wp-config.php ]`, so a restart does not reinstall over an existing site.

The last line locates the daemon instead of naming it:

```bash
exec "$(find /usr/sbin -maxdepth 1 -name 'php-fpm*' -type f -executable | head -n 1)" -F
```

Debian names the binary after the version — `php-fpm8.2` on bookworm — so the `find` is what keeps the script working across base releases. `-F` keeps php-fpm in the foreground; without it the daemon would fork away and the container would exit.

**mariadb.** The dockerfile installs server and client and patches `bind-address` in the packaged `/etc/mysql/mariadb.conf.d/50-server.cnf`. At run time `setup.sh` prepares `/run/mysqld`, and if `/var/lib/mysql/$MYSQL_DATABASE` does not exist it treats this as a first launch: it starts a temporary `mariadbd` with `--skip-networking` on a local socket, waits for it to answer, creates the database and the application user, shuts it down cleanly with `mariadb-admin shutdown`, and only then `exec`s the real server. The half-configured database is never reachable over the network. On later launches the whole block is skipped.

### Start-up order

`depends_on` gives nginx → wordpress → mariadb as the *creation* order, but it only waits for a container to exist, not for the service inside to be ready. Real ordering is enforced in the scripts: WordPress polls the database until it answers. nginx needs no equivalent — if php-fpm is not up yet, early requests return 502 and recover on their own.

All three use `restart: on-failure`. A crashed container comes back; one whose entrypoint exits cleanly stays down and stays visible. `restart: always` would resurrect a broken entrypoint forever and hide exactly the failure the "no hacky loop" rule exists to expose.

### Why the service is always PID 1

`wordpress` and `mariadb` run a shell script as their entrypoint, and both scripts end with `exec` — the php-fpm binary that `init.sh` locates at run time, and `exec mariadbd --user=mysql`. Without it the shell would stay alive as PID 1 with the daemon as its child, and `docker stop` would signal the shell rather than the service. Both are declared in JSON exec form (`ENTRYPOINT ["/init.sh"]`), so Docker runs the script directly rather than wrapping it in `sh -c`.

nginx has no script. `CMD ["nginx", "-g", "daemon off;"]` is the JSON exec form, so Docker runs the binary directly with no shell in between; `daemon off` prevents nginx from forking into the background and exiting.

The result is the same in all three: the service is PID 1, receives `SIGTERM` from `docker stop`, and shuts down properly. There is no `tail -f` and no `sleep infinity` anywhere — the container is alive exactly as long as the service is.

---

## 11. Modifying the project

| Change | Where |
|---|---|
| Domain / login | `nginx.conf` (`server_name`), `create_cert.sh` (`-subj`), `init.sh` (`--url`) |
| Site title | `init.sh`, `wp core install --title` |
| PHP version | Nothing to change — the packages are unversioned, the `www.conf` path is a glob, and `init.sh` finds the binary at run time. The version follows the Debian base |
| Debian base | all three dockerfiles' `FROM` |
| TLS settings | `nginx.conf`, `ssl_protocols` |
| Certificate lifetime / key size | `create_cert.sh`, `-days` and `-newkey` |
| Data location | `docker-compose.yml` volume `device:` and `DATA_DIR` in the `Makefile` — keep them in sync |
| A new WordPress user | `init.sh`, another `wp user create`; add a secret for the password |

After changing a dockerfile, rebuild the affected image — a plain `make down && make` reuses cached layers where it can:

```bash
docker compose -f srcs/docker-compose.yml build --no-cache wordpress
```

Changes to `init.sh` and `setup.sh` only take effect on a rebuild, since both are `COPY`d into the image. Changes inside the WordPress volume take effect immediately, because it is a bind mount.

---

## 12. Troubleshooting

**`make` aborts about missing secrets.** One or more files in `secrets/` does not exist, or exists but is empty — the check uses `[ -s ]`, so a zero-byte file fails it. The message lists the offending paths. See section 5.

**`invalid mount config: bind source path does not exist`.** `/home/$USER/data/mariadb` or `/home/$USER/data/wordpress` is missing. See section 6.

**`docker compose: 'compose' is not a docker command`.** You have Compose V1. See section 1.

**`port is already allocated`.** Something on the host holds 443, often the host's own nginx or apache. `sudo lsof -i :443`, then stop it.

**WordPress loops on `Waiting for MariaDB...`.** `make check-env` first — it catches a mismatched `DB_NAME`/`DB_USER` and a wrong `DB_HOST` outright. If it passes, the remaining cause is the password: `db_password.txt` is not the one the database was initialized with. To see the actual error, which `init.sh` sends to `/dev/null`, run the connection by hand:

```bash
docker exec wordpress sh -c 'mariadb -h "$DB_HOST" -u "$DB_USER" -p"$(cat /run/secrets/db_password)" -e "SELECT 1;"'
```

`Unknown server host` means `DB_HOST`; `Access denied` means the user or the password; `Unknown database` means `DB_NAME`. MariaDB creates the database and user on the *very first* launch only — if you edited `.env` or a secret afterwards, the old data directory still holds the old credentials. `make fclean && make` starts clean, at the cost of all content.

**`502 Bad Gateway`.** php-fpm is not answering on `wordpress:9000`. Check `docker logs wordpress`; usually `init.sh` exited before reaching its final `exec`. Two checks worth running:

```bash
docker exec wordpress find /usr/sbin -maxdepth 1 -name 'php-fpm*'   # the find must match something
docker exec wordpress grep -r '^listen' /etc/php/*/fpm/pool.d/      # must read listen = 9000
```

If the second prints a Unix socket path instead of `9000`, the `sed` in the dockerfile missed its target. Also confirm name resolution with `docker exec nginx getent hosts wordpress`.

**Variables come out empty in `docker compose config`.** `srcs/.env` is missing or in the wrong directory. It has to sit next to `docker-compose.yml`.

**Permission denied under `/home/$USER/data`.** Files are owned by the containers' users. `sudo chown -R $USER:$USER /home/$USER/data`.

**Certificate warning in the browser.** Expected — the certificate is self-signed. Not a bug.

**Starting completely over.**

```bash
make fclean && make
```

This destroys the database and all uploaded content.