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
