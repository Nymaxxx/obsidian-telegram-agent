SHELL := /bin/bash

.PHONY: up down logs setup auth-obsidian

up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f --tail=200

setup:
	./scripts/install.sh

auth-obsidian:
	./scripts/auth-obsidian.sh login
