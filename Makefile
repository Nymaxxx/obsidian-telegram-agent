SHELL := /bin/bash

.PHONY: up down logs auth-claude auth-obsidian

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
