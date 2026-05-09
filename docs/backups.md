# Backups

← Back to [README](../README.md)

> [!IMPORTANT]
> Treat your vault the way you'd treat a database that an automated process can write to: assume something will eventually go wrong, and make sure you can roll back.

The default deny list blocks `rm` and other directly-destructive commands, but the agent can still overwrite, mangle, or `mv` notes into `.trash/`. A misunderstood instruction, a bad merge, or a model slip can still damage or lose work. Obsidian Sync version history helps for individual files, but it has limits and shouldn't be your only safety net.

**Recommended: turn the vault into a git repo.**

```bash
cd vault
git init
git add .
git commit -m "baseline"
```

Then either:

- Push to a private GitHub/GitLab repo and let the agent commit periodically (you can ask it to: "commit the vault with a message describing what changed").
- Or run a cron job on the VPS that snapshots `git add -A && git commit -m "auto $(date -Iseconds)"` every hour.

**Other options:**

- **Restic / Borg / rsync** to off-site storage (S3, B2, another VPS) on a daily schedule.
- **Filesystem snapshots** if your VPS supports them (Hetzner / DigitalOcean snapshots cover the whole disk).
- **Obsidian Sync version history** — useful for "I edited the wrong line", but bounded retention and per-file scope; not a substitute for the above.

**Before pointing the agent at an existing vault you care about**, take a manual full-vault backup (`tar czf vault-backup-$(date +%F).tar.gz vault/`) and store it somewhere off-server. Test recovery at least once.

## Concurrent writes

Both `takopi` and `obsidian-headless` mount the same `/vault` read-write. There's no file-level locking between them: in theory, Obsidian Sync can write a file in the exact moment the agent is reading or editing it, and one of the writes will lose. In practice this is rare for a personal vault (Sync writes are quick, agent edits are quick, the window is small), but it's a real edge case — another reason to keep the backups above.
