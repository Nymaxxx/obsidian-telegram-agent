SHELL := /bin/bash

.PHONY: bootstrap render up down logs auth-claude auth-obsidian

bootstrap:
	./scripts/bootstrap.sh

render:
	./scripts/render-singbox-config.sh

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

auth-claude:
	./scripts/auth-claude.sh

auth-obsidian:
	./scripts/auth-obsidian.sh login
