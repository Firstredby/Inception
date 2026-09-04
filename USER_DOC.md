# User documentation

This document is for anyone who needs to run the stack and use the site: an end user, or an administrator who did not build the project. It assumes the project is already installed on the machine. If you are setting it up from scratch or changing how it works, read [DEV_DOC.md](DEV_DOC.md) instead.

---

## 1. What the stack provides

Running this project gives you a self-contained WordPress website served over HTTPS. It is made of three services, each in its own container:

| Service | What it does for you | Do you interact with it directly? |
|---|---|---|
| **nginx** | The web server. Handles the HTTPS connection and is the only way in from outside. | Indirectly — it is what your browser talks to. |
| **wordpress** | The site itself: pages, posts, themes, the admin panel. | Yes, through the browser. |
| **mariadb** | The database. Stores every post, page, comment, setting and user account. | No — it is not reachable from outside the stack. |

Two WordPress accounts are created automatically on the first launch:

- an **administrator**, who can change anything, including themes, plugins and users;
- a second user with the **author** role, who can write and publish their own posts but cannot change site settings.

The website is available at **https://ishchyro.42.fr** and nowhere else. There is no plain HTTP version — port 80 is not open at all.

---

## 2. Starting and stopping the project

All commands are run from the root of the project directory, the one containing the `Makefile`.

### Start

```bash
make
```

This builds the images if needed and starts all three containers in the background. The very first run takes several minutes because the images are built from scratch; later runs take a few seconds.

To start it in the foreground instead, with all logs printed to your terminal, use `make up`. Press `Ctrl+C` to stop it.

### Stop

```bash
make down
```

This stops and removes the containers. **Your site is not lost.** Posts, pages, uploads, users and settings all live on the host machine and are still there the next time you run `make`.

### Restart

```bash
make down && make
```

### Commands that destroy data

Two commands delete things permanently. Read this before using either.

| Command | What it removes |
|---|---|
| `make clean` | Stops the stack, then removes **every** Docker container and image on the machine — not only this project's. Your site data survives. |
| `make fclean` | Everything `make clean` does, **plus** deletes `/home/<your-user>/data`. This erases the database and the entire WordPress installation. Every post, page, upload, user and setting is gone. |
| `make re` | `make fclean` followed by `make` — a rebuild from nothing, on an empty site. |

After `make fclean`, the next `make` gives you a brand new site with the two default accounts and no content.

---

## 3. Accessing the website and the admin panel

### The website

Open **https://ishchyro.42.fr** in a browser.

Your browser will show a security warning the first time — something like "Your connection is not private" or "Warning: Potential Security Risk Ahead". **This is expected.** The site uses a self-signed certificate, meaning the project generated its own certificate rather than buying one from a recognised authority. The connection is still encrypted; the browser simply cannot vouch for who is on the other end. Click through the warning (usually "Advanced", then "Proceed" or "Accept the risk"). You only have to do this once per browser.

If the address does not resolve at all, the machine is missing its `/etc/hosts` entry. See [DEV_DOC.md](DEV_DOC.md), section 3.

### The admin panel

Go to **https://ishchyro.42.fr/wp-admin** and log in with the administrator username and password. From there you can write posts, install themes, manage users and change every site setting.

The author account logs in at the same address but sees a much smaller menu — it can create and publish its own posts and nothing else.

---

## 4. Credentials

### Where they live

Credentials are split across two places, and **neither is ever committed to Git**.

**Passwords** are stored one per file in the `secrets/` directory at the root of the project:

| File | Password for |
|---|---|
| `secrets/db_password.txt` | The database user WordPress connects as |
| `secrets/wp_admin_password.txt` | The WordPress administrator |
| `secrets/wp_user_password.txt` | The second WordPress user (author) |

Each file contains the password and nothing else. Docker mounts them read-only inside the containers that need them, at `/run/secrets/`. They are deliberately kept out of environment variables, which would expose them to anyone able to run `docker inspect`.

> **There is no root password, by design.** The database's `root` account is not protected by a password and does not need to be: it uses `unix_socket` authentication, which checks the system user of whoever connects rather than a password. In practice that means root can only be used by the `root` user from a shell inside the MariaDB container, and cannot be used over the network at all. WordPress never connects as root — it uses the ordinary account whose password is in `secrets/db_password.txt`.

**Usernames, emails and the database name** are in `srcs/.env`. This file holds no passwords:

| Variable | Meaning |
|---|---|
| `WP_ADMIN`, `WP_EMAIL` | Administrator login and email |
| `WP_USER`, `WP_USER_EMAIL` | Author login and email |
| `MYSQL_DATABASE`, `MYSQL_USER` | Database name and application user |
| `DB_NAME`, `DB_USER`, `DB_HOST` | The same values, as WordPress reads them |

To find out the administrator's username, look at `WP_ADMIN` in `srcs/.env`; the matching password is in `secrets/wp_admin_password.txt`.

### Keeping them safe

- `secrets/` and `srcs/.env` are listed in `.gitignore`, so they cannot be pushed by accident. Do not remove those lines.
- Restrict the files to your own account: `chmod 600 secrets/*.txt`
- Never paste a password into `srcs/.env`. That file is for names, not secrets.

### Changing a password

**A WordPress password** — administrator or author — is changed from the admin panel, under *Users*. This is the normal way and takes effect immediately. Note that the file in `secrets/` is only read when a site is first created, so it will no longer match; update it by hand if you want the two to agree.

**The database password** cannot simply be edited in `secrets/db_password.txt`. The database user was created with the old password on the first launch and still expects it, so changing the file alone leaves WordPress unable to connect. Two things have to change together: the password stored in the database, and the copy WordPress has written into its configuration.

With the stack running:

```bash
# 1. Change it in the database. Root works without a password from inside
#    the container, so no credentials are needed for this step.
docker exec -it mariadb mariadb -u root \
    -e "ALTER USER '<db-user>'@'%' IDENTIFIED BY '<new-password>'; FLUSH PRIVILEGES;"

# 2. Tell WordPress about it.
docker exec -it wordpress wp --allow-root config set DB_PASSWORD '<new-password>'

# 3. Update the file, so a future rebuild uses the same value.
echo '<new-password>' > secrets/db_password.txt
```

Replace `<db-user>` with the value of `DB_USER` in `srcs/.env`. Reload the site to confirm it still works.

If the site has no content worth keeping, `make fclean && make` is simpler: edit the secret file first, and the new site is built with the new password from the start. This destroys everything, so only do it on an empty site.

---

## 5. Checking that everything is running

### The quick check

```bash
docker ps
```

You should see exactly three containers — `nginx`, `wordpress` and `mariadb` — all with a status beginning `Up`. If one is missing, or shows `Restarting` or `Exited`, that service is the problem.

```bash
curl -kI https://ishchyro.42.fr
```

A healthy stack answers `HTTP/1.1 200 OK`. The `-k` tells curl not to object to the self-signed certificate; `-I` asks for headers only.

### Reading the logs

```bash
make logs
```

For a single service, and to follow it live:

```bash
docker logs -f wordpress
```

On a healthy first launch you will see, in this order: MariaDB reporting a first launch and creating the database, WordPress printing `Waiting for MariaDB...` once or twice, then wp-cli installing the site. On later launches MariaDB reports an existing database and skips initialization.

### Checking that data survives

```bash
make down && make
```

Reload the site. Your posts should still be there. If they are not, the data directory is not persisting correctly and a developer should look at it.

### Common symptoms

| What you see | What it usually means |
|---|---|
| Browser cannot find `ishchyro.42.fr` | The `/etc/hosts` entry is missing on this machine |
| Certificate warning | Normal. Self-signed certificate — click through it |
| `502 Bad Gateway` | nginx is up but WordPress is not answering yet. Wait a few seconds on a first launch; if it persists, check `docker logs wordpress` |
| Page loads but looks unstyled | nginx is serving, but the shared files are incomplete — check `docker logs wordpress` |
| `docker ps` shows only two containers | One service failed to start; its logs will say why |
| `make` stops with a message about missing secrets | One or more files in `secrets/` does not exist. See section 4 |

If a service is stuck, the first thing to try is `make down && make`. If that does not help, the problem is a configuration one and belongs in [DEV_DOC.md](DEV_DOC.md).
