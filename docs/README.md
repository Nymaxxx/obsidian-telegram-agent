---
title: "Documentation — Obsidian Telegram Agent"
description: "Long-form docs for the self-hosted Telegram bot that gives Claude Code shell-level access to your Obsidian vault — install, configure, secure, back up."
---

# Documentation

Long-form docs for [obsidian-telegram-agent](../README.md). The main README covers install and a quick start; everything below goes deeper.

| Topic | What's inside |
|---|---|
| [Configuration](configuration.md) | `.env` settings, repository layout, agent behavior (`CLAUDE.base.md` / `CLAUDE.local.md` / `CLAUDE_EXTRA_INSTRUCTIONS` layers), choosing a model |
| [Sessions and conversation flow](sessions.md) | How session resumption works, `/new` and `/cancel`, context accumulation |
| [Vault isolation](vault-isolation.md) | Hide folders from the agent (CLAUDE.md vs tmpfs), soft-delete via `.trash/` |
| [Auto-deploy with GitHub Actions](auto-deploy.md) | CI workflows, required secrets, what persists, SSH setup for CI |
| [Operations and troubleshooting](operations.md) | Daily commands, Makefile shortcuts, common issues |
| [Backups](backups.md) | Why you need them, recommended approaches, concurrent-write caveat |
| [Security notes](security.md) | Threat model, deny list, prompt-injection notes, full VPS hardening checklist |
| [Audit and improvement plan](improvement-plan.md) | July 2026 codebase audit, ecosystem review, staged improvement checklist |
| [SDK bridge plan](sdk-bridge-plan.md) | Assessment and phased design for replacing Takopi with a purpose-built bridge on the Claude Agent SDK |
