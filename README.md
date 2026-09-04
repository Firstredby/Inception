*This project has been created as part of the 42 curriculum by ishchyro.*

# Inception

## Description

Inception is a system administration project. The goal is to build a small but complete web infrastructure from scratch, using Docker, inside a virtual machine — and to write every image by hand instead of pulling ready-made ones from DockerHub.

The result is a WordPress site reachable only over TLS, split across three containers that each run exactly one service:

| Container   | Service                                   | Base image        | Reachable from |
|-------------|-------------------------------------------|-------------------|----------------|
| `nginx`     | TLS termination and reverse proxy         | `debian:bullseye` | the host, on port `443` |
| `wordpress` | WordPress with php-fpm 7.4, set up by wp-cli | `debian:bullseye` | the internal network only |
| `mariadb`   | Database                                  | `debian:bullseye` | the internal network only |

The three containers are joined by one user-defined Docker network, share two persistent volumes on the host, and receive their passwords through Docker secrets rather than through the environment. Everything is orchestrated by a single `docker-compose.yml` driven from a `Makefile`.

---

## Project description

### The role of Docker in this project

Docker is what makes the "one service per container" requirement expressible at all. Each service gets its own filesystem, its own process tree and its own network identity, while all three still share a single kernel and start in seconds. In practice Docker is used here in four distinct ways:

1. **Images as build recipes.** Each service has a `dockerfile` that starts from `debian:bullseye` and installs, configures and prepares exactly one daemon. No image is pulled ready-made from DockerHub — only the Debian base is, which the subject allows.
2. **Compose as the orchestrator.** `docker-compose.yml` declares the three services, the network they share, the two volumes, and the three secrets. It also encodes start-up order through `depends_on`.
3. **The network as an isolation boundary.** Only nginx publishes a port. MariaDB and php-fpm are addressable by service name from inside the network, and by nothing from outside it.
4. **Volumes for state.** Container filesystems are disposable; the database and the WordPress installation are not, so both live on the host and are mounted in.

### Sources included in the project

```
.
├── Makefile                       # entry point: build, run, stop, clean
├── .gitignore                     # excludes secrets/ and .env
├── README.md
├── USER_DOC.md                    # running and using the site
├── DEV_DOC.md                     # setting up, building, containers, data
├── secrets/                       # not in git — you create it yourself
│   ├── db_password.txt
│   ├── wp_admin_password.txt
│   └── wp_user_password.txt
└── srcs/
    ├── .env.example               # template for the non-sensitive variables
    ├── .env                       # not in git
    ├── docker-compose.yml         # services, network, volumes, secrets
    └── requirements/
        ├── nginx/
        │   ├── dockerfile         # nginx + openssl on Debian bullseye
        │   ├── conf/nginx.conf    # one TLS vhost, FastCGI pass to php-fpm
        │   └── tools/create_cert.sh   # self-signed certificate, generated at build time
        ├── wordpress/
        │   ├── dockerfile         # php7.4-fpm, WordPress tarball, wp-cli
        │   └── tools/init.sh      # waits for the DB, installs WP, execs php-fpm
        └── mariadb/
            ├── dockerfile         # mariadb-server, bind-address patched with sed
            ├── config/50-server.cnf   # kept for reference; not copied into the image
            └── tools/setup.sh     # first-run database and user creation, execs mariadbd
```

### How a request travels

1. The browser resolves `ishchyro.42.fr` to `127.0.0.1` through `/etc/hosts` and opens a TLS connection on port 443.
2. nginx terminates TLS. Static files are served directly from `/var/www/html`; anything matching `location ~ \.php$` is handed on over FastCGI to `wordpress:9000`.
3. php-fpm executes the PHP. Because nginx and WordPress mount the same volume at the same path, the `SCRIPT_FILENAME` nginx computes points at a file php-fpm can actually open.
4. WordPress connects to `mariadb:3306` with the credentials written into `wp-config.php` at install time.

### Main design choices

**Debian bullseye as the base.** The subject asks for the penultimate stable release of Alpine or Debian. Bullseye is Debian 11, one release behind Bookworm. Debian was chosen over Alpine because its packaged `mariadb-server` and `php7.4-fpm` need no extra work, and because glibc avoids the musl surprises Alpine occasionally produces with PHP extensions.

**One long-lived process per container, and it is PID 1.** Two of the three services run a shell script as their entrypoint, and both scripts end with `exec` — `exec php-fpm7.4 -F` and `exec mariadbd --user=mysql`. The shell replaces itself with the daemon rather than forking it, so the daemon inherits PID 1. nginx needs no script at all: `CMD ["nginx", "-g", "daemon off;"]` is the JSON exec form, which runs the binary directly without a shell in between, and `daemon off` stops nginx backgrounding itself. In all three cases the service is PID 1, receives `SIGTERM` from `docker stop` and shuts down cleanly. There is no `tail -f`, no `sleep infinity`, no `while true`. The container's liveness is the service's liveness, which is exactly the point of the rule.

**`restart: on-failure` rather than `restart: always`.** A container that crashes comes back; a container whose entrypoint exits cleanly stays down and is visible as a problem. `always` would resurrect a broken entrypoint forever and hide precisely the failure mode the "no hacky loop" rule is meant to expose.

**Readiness is checked, not guessed.** Compose's `depends_on` waits for a container to be created, not for the service inside it to accept connections. So `init.sh` polls the database with `mariadb -h "$DB_HOST" ... -e "SELECT 1;"` until it answers, instead of sleeping for an arbitrary number of seconds. nginx needs no such loop: if php-fpm is not up yet, early requests return 502 and recover on their own.

**MariaDB initializes behind a closed door.** On first launch `setup.sh` starts a temporary `mariadbd` with `--skip-networking` and a local socket, creates the database and the application user, then shuts it down with `mariadb-admin shutdown` before starting the real server. The half-configured database is never reachable over the network. On later launches the presence of the data directory makes the whole block a no-op.

**The certificate is generated at build time.** `create_cert.sh` runs inside the nginx `dockerfile`, producing a 2048-bit RSA self-signed certificate with `CN=ishchyro.42.fr`, valid for a year. It needs no runtime state and is therefore deterministic; the trade-off is that it only refreshes on rebuild, which is acceptable for a development certificate. nginx accepts TLSv1.2 and TLSv1.3 only, and port 80 is never published.

**Credentials never enter the repository.** Passwords live in `secrets/`, names and emails live in `srcs/.env`, and both are gitignored. The `Makefile` runs a `check-secrets` target before anything else and refuses to build if any of the three secret files is absent *or empty*, listing exactly which ones.

---

### Virtual Machines vs Docker

A virtual machine virtualizes hardware. The hypervisor presents emulated devices to a full guest operating system with its own kernel, and that guest boots as if it were on real metal. A container virtualizes the operating system instead: Docker uses namespaces to give a process its own view of the filesystem, network, PIDs and users, and cgroups to cap what it can consume — but the process runs on the *host's* kernel, as an ordinary process.

| | Virtual machine | Docker container |
|---|---|---|
| Kernel | Its own | Shared with the host |
| Start-up | Tens of seconds to minutes | Milliseconds to seconds |
| Footprint | Gigabytes, fixed RAM allocation | Megabytes, RAM used on demand |
| Isolation | Strong — a hypervisor boundary | Weaker — a kernel boundary |
| Guest OS | Any, including a different kernel | Linux only, on a Linux host |

For this project containers are the obvious fit: three services that all want Linux, that need to start and be torn down constantly during development, and whose images should be reproducible from a text file. Running three VMs to serve one WordPress site would cost gigabytes and minutes for isolation nobody needs here.

The trade-off is real, though, and worth stating. Sharing a kernel means a kernel vulnerability is a shared vulnerability, and a container escape puts an attacker on the host. VMs remain the right answer for hostile multi-tenancy, for running a different kernel or a non-Linux guest, and wherever a hardware-level boundary is a compliance requirement. It is also worth noting that this project itself runs inside a VM — the two technologies are complementary rather than competing.

### Secrets vs Environment Variables

Both mechanisms inject configuration into a container, and this project deliberately uses each for a different kind of value.

Environment variables are declared in the compose file and read from `srcs/.env`. They are convenient and universally supported, but they leak by design: `docker inspect` prints them in full, they appear in the container's image and container metadata, they are inherited by every child process, and any crash handler or debug dump that serializes the environment carries them along. A variable is not a place to put a password.

Docker secrets are files. Compose reads `secrets/db_password.txt` from the host and mounts it read-only at `/run/secrets/db_password` inside only the containers that declare it. `docker inspect` shows that a secret is attached, not its contents. Access is per-service, so the WordPress admin password never reaches the database container and the database password reaches both, because both need it:

| Secret | mariadb | wordpress |
|---|:---:|:---:|
| `db_password` | ✓ | ✓ |
| `wp_admin_password` | | ✓ |
| `wp_user_password` | | ✓ |

Each entrypoint reads what it needs at start-up:

```bash
MYSQL_PASSWORD=$(cat /run/secrets/db_password)
```

So the split in this project is: **environment variables for what is not secret** — database name, user name, site URL, admin login, emails — and **secrets for every password**. A useful detail of the file-based approach is that a secret can be rotated by replacing a file and restarting the service, without rebuilding an image or editing a compose file.

### Docker Network vs Host Network

With `network_mode: host` a container skips network namespacing entirely and uses the host's stack directly. There is no NAT and no port mapping, so it is marginally faster and simpler — and every port a container opens is open on the host, containers can reach each other over `localhost`, and two services that both want port 3306 simply collide.

This project uses a user-defined bridge network named `inception`. Docker creates a virtual switch, gives each container an address on it, and — importantly, and unlike the *default* bridge — runs an embedded DNS server so containers resolve each other by service name. That is why `DB_HOST=mariadb` and `fastcgi_pass wordpress:9000` work with no hardcoded addresses and survive a container getting a new IP after a restart.

The decisive advantage is what is *not* exposed. Only nginx declares `ports: "443:443"`. MariaDB listens on 3306 and php-fpm on 9000, both reachable from inside `inception` and from nowhere else — no firewall rule required, because the port was never published in the first place. On the host network, the database would be listening on the VM's interface and would have to be protected by other means.

The subject forbids `network_mode: host` and `--link` explicitly. `--link` is in any case the deprecated predecessor of this mechanism: it wired containers together by injecting `/etc/hosts` entries, one pair at a time, with no DNS and no way to reconnect after a restart.

### Docker Volumes vs Bind Mounts

A container's writable layer disappears with the container, so anything that must survive has to live outside it. Docker offers two ways.

A **named volume** is storage Docker creates and manages under `/var/lib/docker/volumes/`. It is portable, backed up and migrated through Docker's own commands, works identically across hosts, and its permissions are set up by Docker on first use.

A **bind mount** attaches a specific host directory to a path in the container. The host controls the exact location and the files are directly visible and editable, which is why bind mounts dominate in development. The cost is portability — the path must exist on every machine — and permissions, since the container writes as `mysql` or `www-data` and the host user may then be unable to touch the resulting files.

This project uses named volumes that are, in substance, bind mounts:

```yaml
volumes:
  mariadb:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /home/${USER}/data/mariadb
```

`type: none` with `o: bind` tells the `local` driver to bind an existing host directory rather than allocate storage of its own. The result is addressed as a named volume in the service definitions while the data physically lives at `/home/$USER/data/mariadb` and `/home/$USER/data/wordpress` — which is what the subject requires. The WordPress volume is mounted into two containers at once, since nginx must read the static files that php-fpm executes.

Two consequences follow from choosing bind semantics. The host directories must exist before `docker compose up`, or the mount fails outright — which is why `make all` creates them. And because the files are owned by the container's users, `make clean` runs `sudo chown -R $USER:$USER` on the data directory to hand it back.

---

## Instructions

### Requirements

- Docker Engine with the Compose V2 plugin — the `Makefile` calls `docker compose`, not `docker-compose`
- GNU Make
- `sudo` rights, for the `/etc/hosts` entry and for the ownership fix in `make clean`

### 1. Clone

```bash
git clone https://github.com/Firstredby/Inception.git
cd Inception
```

### 2. Point the domain at your machine

nginx serves a single vhost, `ishchyro.42.fr`, and the certificate is issued for exactly that name:

```bash
echo "127.0.0.1 ishchyro.42.fr" | sudo tee -a /etc/hosts
```

### 3. Fill in the environment file

`docker compose` loads `srcs/.env` automatically, because the compose file sits in `srcs/`.

```bash
cp srcs/.env.example srcs/.env
```

| Variable | Used by | Meaning |
|---|---|---|
| `MYSQL_DATABASE` | mariadb | Database created on first launch |
| `MYSQL_USER` | mariadb | Application user created on first launch |
| `DB_NAME` | wordpress | Must equal `MYSQL_DATABASE` |
| `DB_USER` | wordpress | Must equal `MYSQL_USER` |
| `DB_HOST` | wordpress | Service name of the database — `mariadb` |
| `WP_ADMIN` | wordpress | Administrator login. Must **not** contain `admin` or `administrator` — the subject forbids it |
| `WP_EMAIL` | wordpress | Administrator email |
| `WP_USER` | wordpress | Second user, created with the `author` role |
| `WP_USER_EMAIL` | wordpress | Second user's email |

The database name and user appear twice because MariaDB and WordPress read them independently. Keep the pairs in sync, or WordPress will try to open a database that does not exist.

### 4. Create the secrets

```bash
mkdir -p secrets
echo 'db_pass_here'       > secrets/db_password.txt
echo 'wp_admin_pass_here' > secrets/wp_admin_password.txt
echo 'wp_user_pass_here'  > secrets/wp_user_password.txt
chmod 600 secrets/*.txt
```

`make` aborts and lists the offending files if any of the three is absent or empty.

### 5. Build and run

```bash
make
```

The first build takes a few minutes — three Debian images, `apt` installs, the WordPress tarball and wp-cli. The data directories `/home/$USER/data/{mariadb,wordpress}` are created for you.

Then open **https://ishchyro.42.fr** and accept the self-signed certificate warning once. The admin panel is at `/wp-admin`.

### Make targets

| Target | What it does |
|---|---|
| `make` / `make all` | Verifies the secrets, creates the data directories, builds and starts everything detached |
| `make up` | Starts in the foreground, logs on stdout |
| `make down` | Stops and removes the containers |
| `make logs` | Dumps logs from all services |
| `make clean` | `down`, then removes **all** containers and images on the machine and fixes ownership of the data directory |
| `make fclean` | `clean`, then deletes `/home/$USER/data` — **destroys the database and the site** |
| `make re` | `fclean` + `all`, a full rebuild from zero |

> `clean` removes every container and image on the host, not only this project's. That is convenient inside the 42 VM and destructive anywhere else.

### Verifying

```bash
docker ps                          # three containers, all Up
curl -kI https://ishchyro.42.fr    # HTTP/1.1 200 OK
make down && make                  # posts survive a restart
```

Two further documents sit alongside this one at the root of the repository. **[USER_DOC.md](USER_DOC.md)** is for running and using the site: starting and stopping the stack, reaching the admin panel, finding and managing credentials, and checking that the services are healthy. **[DEV_DOC.md](DEV_DOC.md)** is for working on the project: setting the environment up from scratch, building with the `Makefile` and Compose, managing containers and volumes, and where the data is stored and how it persists.

---

## Resources

**Docker**
- Docker documentation — https://docs.docker.com/
- Compose file reference — https://docs.docker.com/reference/compose-file/
- Compose secrets — https://docs.docker.com/compose/how-tos/use-secrets/
- Networking overview and user-defined bridges — https://docs.docker.com/engine/network/
- Volumes and bind mounts — https://docs.docker.com/engine/storage/volumes/
- Dockerfile reference, including `ENTRYPOINT` vs `CMD` — https://docs.docker.com/reference/dockerfile/
- "Namespaces in operation", LWN — https://lwn.net/Articles/531114/

**nginx and php-fpm**
- nginx documentation — https://nginx.org/en/docs/
- `ngx_http_ssl_module` — https://nginx.org/en/docs/http/ngx_http_ssl_module.html
- `ngx_http_fastcgi_module` — https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html
- php-fpm configuration — https://www.php.net/manual/en/install.fpm.configuration.php

**WordPress and MariaDB**
- WP-CLI handbook — https://make.wordpress.org/cli/handbook/
- `wp core install` — https://developer.wordpress.org/cli/commands/core/install/
- Editing `wp-config.php` — https://developer.wordpress.org/advanced-administration/wordpress/wp-config/
- MariaDB configuration files — https://mariadb.com/kb/en/configuring-mariadb-with-option-files/
- `mariadb-install-db` and first-run setup — https://mariadb.com/kb/en/mariadb-install-db/

**TLS**
- OpenSSL `req` — https://docs.openssl.org/master/man1/openssl-req/
- Mozilla TLS configuration guidelines — https://wiki.mozilla.org/Security/Server_Side_TLS

**GNU Make**
- GNU Make manual, recipe syntax and `.PHONY` — https://www.gnu.org/software/make/manual/make.html

### Use of AI

AI (Claude) was used mainly as a way to understand the subject, not as a source of solutions. The infrastructure was written by hand, with one exception, noted below.

**Understanding the topic.** Most of the AI use was conceptual: asking what a given piece of Docker actually does before writing any of it. Why `ENTRYPOINT` differs from `CMD` and why `exec` at the end of an entrypoint matters for signal handling; what a user-defined bridge gives you that the default bridge does not; how Compose secrets are actually delivered to a container and why that beats an environment variable; what `type: none` with `o: bind` means for the `local` volume driver. These were explanations, not code — the equivalent of asking a question about the documentation rather than asking for an answer.

**The MariaDB setup script.** This is the exception. `srcs/requirements/mariadb/tools/setup.sh` was written with AI assistance, specifically the first-run initialization pattern: starting a temporary `mariadbd` with `--skip-networking` on a local socket, waiting for it to answer, creating the database and user through it, then shutting it down cleanly with `mariadb-admin shutdown` before `exec`ing the real server. Getting a database to initialize itself on first launch without ever being exposed half-configured was the part I could not work out unaided.

**Documentation.** This `README.md`, along with `USER_DOC.md` and `DEV_DOC.md`, was drafted by AI from a reading of the repository, then reviewed and corrected. At least one claim in the first draft was simply wrong and was cut after being checked.

**Code review.** The AI was asked to look over the `Makefile` and `docker-compose.yml`. It reported five issues; each was verified by hand rather than taken on trust. Two held up: a stray backtick in the `mariadb` build context path, and a `check-secrets` recipe whose backslash continuations swallowed `exit 1` as an argument to `echo`, so the check printed a warning and then let the build run anyway. One was cosmetic. One was outright wrong — a claim that `echo` leaves a stray newline in the password files, which it does not, because command substitution strips trailing newlines. The rewritten `check-secrets` recipe, which lists the missing files and actually aborts, came out of that exchange.

Everything else — the three dockerfiles, `init.sh`, `create_cert.sh`, `nginx.conf`, `docker-compose.yml` and the rest of the `Makefile` — was written by hand.

The main lesson: AI output about your own code has to be checked against the code. Of the five problems reported in the review, only two were real, and it took actually running the commands to find out which.

---

## Author

**ishchyro** — [Firstredby](https://github.com/Firstredby)
