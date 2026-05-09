SHELL := /bin/bash

.PHONY: up up-dev pull down logs setup setup-ci bootstrap auth-obsidian

up:
	docker compose pull
	docker compose up -d

up-dev:
	docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build

pull:
	docker compose pull

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

setup:
	bash scripts/install.sh

setup-ci:
	NONINTERACTIVE=1 bash scripts/install.sh

bootstrap:
	bash scripts/bootstrap.sh

auth-obsidian:
	bash scripts/auth-obsidian.sh login
