COMPOSE = docker compose -f srcs/docker-compose.yml

DATA_DIR = /home/$(USER)/data

SECRETS = \
	secrets/db_password.txt \
	secrets/db_root_password.txt \
	secrets/wp_admin_password.txt \
	secrets/wp_user_password.txt

all: check-secrets
	mkdir -p $(DATA_DIR)/mariadb
	mkdir -p $(DATA_DIR)/wordpress
	$(COMPOSE) up -d --build

logs:
	$(COMPOSE) logs

check-secrets:
	@for secret in $(SECRETS); do \
		if [ ! -f $$secret ]; then \
			echo "ERROR: Required secrets are missing." \
			echo "" \
			echo "Expected files:" \
			echo "  secrets/db_password.txt" \
			echo "  secrets/db_root_password.txt" \
			echo "  secrets/wp_admin_password.txt" \
			echo "  secrets/wp_user_password.txt" \
			echo "" \
			echo "Aborting..." \
			exit 1; \
		fi; \
	done

up:
	$(COMPOSE) up

down:
	$(COMPOSE) down

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

.PHONY: all logs check-secrets up down clean fclean re