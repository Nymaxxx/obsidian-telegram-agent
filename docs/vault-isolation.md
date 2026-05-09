# Vault isolation

← Back to [README](../README.md)

Two ways to hide folders from the agent:

**1. Soft (CLAUDE.local.md instruction):** list the folder in the `Off-limits paths` section of [`vault/CLAUDE.local.md`](../templates/CLAUDE.local.md.example) (or in the `CLAUDE_EXTRA_INSTRUCTIONS` env/Variable). Claude will treat it as if it doesn't exist. Easy to add and uncomplicated, but relies on the model following instructions.

**2. Hard (Docker tmpfs):** mount a tmpfs over the folder in [`docker-compose.yml`](../docker-compose.yml). Claude physically cannot read, list, or write anything there — even if it ignores the instructions.

```yaml
# docker-compose.yml → takopi service
tmpfs:
  - "/vault/Archive:size=1k,mode=0000"
  - "/vault/private:size=1k,mode=0000"
```

The compose file ships with the `tmpfs:` block commented out — uncomment it and add the paths that are sensitive in your vault. Use both layers (soft + hard) for anything you really don't want the model to touch. Obsidian Headless is unaffected and syncs those folders normally.

## Soft-delete via `.trash/`

The agent has no `rm`. When you tell it "delete this note", it moves the file to `/vault/.trash/` instead. To purge for real:

```bash
docker compose exec takopi ls -la /vault/.trash/

sudo rm -rf vault/.trash/* && mkdir -p vault/.trash
```

Obsidian Sync will sync `.trash/` like any other folder. If you don't want it on your other devices, add `.trash/` to your Obsidian Sync excluded paths.
