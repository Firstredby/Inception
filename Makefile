COMPOSE = docker compose -f srcs/docker-compose.yml

DATA_DIR = /home/$(USER)/data

ENV_FILE = srcs/.env

SECRETS = \
	secrets/db_password.txt \
	secrets/wp_admin_password.txt \
	secrets/wp_user_password.txt

ENV_VARS = \
	MYSQL_DATABASE \
	MYSQL_USER \
	DB_NAME \
	DB_USER \
	DB_HOST \
	WP_ADMIN \
	WP_EMAIL \
	WP_USER \
	WP_USER_EMAIL

all: check-secrets check-env
	mkdir -p $(DATA_DIR)/mariadb
	mkdir -p $(DATA_DIR)/wordpress
	$(COMPOSE) up -d --build

up:
	$(COMPOSE) up

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs

check-secrets:
	@missing=""; \
	for secret in $(SECRETS); do \
		[ -s "$$secret" ] || missing="$$missing $$secret"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "ERROR: required secret files are missing or empty:"; \
		echo ""; \
		for m in $$missing; do echo "  $$m"; done; \
		echo ""; \
		echo "Create each one with:  echo 'password' > <file>"; \
		echo "Aborting."; \
		exit 1; \
	fi

check-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "ERROR: $(ENV_FILE) is missing."; \
		echo ""; \
		echo "Create it with:  cp srcs/.env.example $(ENV_FILE)"; \
		echo "Aborting."; \
		exit 1; \
	fi
	@get() { grep -E "^[[:space:]]*$$1[[:space:]]*=" $(ENV_FILE) | tail -n1 | cut -d= -f2- | tr -d "[:space:]"; }; \
	missing=""; \
	for var in $(ENV_VARS); do \
		[ -n "$$(get $$var)" ] || missing="$$missing $$var"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "ERROR: variables unset or empty in $(ENV_FILE):"; \
		echo ""; \
		for m in $$missing; do echo "  $$m"; done; \
		echo ""; \
		echo "Aborting."; \
		exit 1; \
	fi; \
	bad=0; \
	if [ "$$(get DB_NAME)" != "$$(get MYSQL_DATABASE)" ]; then \
		echo "ERROR: DB_NAME must match MYSQL_DATABASE."; bad=1; \
	fi; \
	if [ "$$(get DB_USER)" != "$$(get MYSQL_USER)" ]; then \
		echo "ERROR: DB_USER must match MYSQL_USER."; bad=1; \
	fi; \
	if [ "$$(get DB_HOST)" != "mariadb" ]; then \
		echo "ERROR: DB_HOST must be 'mariadb' - the compose service name."; bad=1; \
	fi; \
	if echo "$$(get WP_ADMIN)" | grep -qi "admin"; then \
		echo "ERROR: WP_ADMIN must not contain 'admin' - the subject forbids it."; bad=1; \
	fi; \
	if [ "$$bad" -ne 0 ]; then \
		echo ""; \
		echo "Aborting."; \
		exit 1; \
	fi

clean:
	$(COMPOSE) down
	docker ps -aq | xargs -r docker rm -f
	docker images -aq | xargs -r docker rmi -f
	@if [ -d $(DATA_DIR) ]; then \
		sudo chown -R $(USER):$(USER) $(DATA_DIR) 2>/dev/null; \
	fi

fclean: clean
	rm -rf $(DATA_DIR)

re: fclean all

.PHONY: all up down logs check-secrets check-env clean fclean re