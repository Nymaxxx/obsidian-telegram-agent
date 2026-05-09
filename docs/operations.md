# Operations and troubleshooting

← Back to [README](../README.md)

## Typical operations

```bash
docker compose logs -f takopi
docker compose logs -f obsidian-headless

docker compose exec takopi sh -lc 'cat /state/.takopi/takopi.toml'

docker compose exec takopi sh -lc 'cat /state/.claude/settings.json'

./scripts/auth-obsidian.sh status

docker inspect --format='{{.State.Health.Status}}' takopi
```

Or use the Makefile shortcuts:

```bash
make up       # docker compose pull && docker compose up -d
make up-dev   # build locally with docker-compose.dev.yml override
make down     # docker compose down
make logs     # docker compose logs -f --tail=200
```

## Vault file ownership

The containers run as root, so files the agent creates are owned by root on the host. If you want to edit `vault/` directly from your normal user account (or commit it to git locally), reclaim ownership:

```bash
sudo chown -R "$USER:$USER" vault/
```

Re-run after big bulk operations if needed.

## Troubleshooting

<details>
<summary><strong>Takopi crashes in a restart loop ("error: already running")</strong></summary>

A stale lock file is left from a previous run:

```bash
rm -f ~/obsidian-telegram-agent/takopi-state/.takopi/takopi.lock
docker compose restart takopi
```

</details>

<details>
<summary><strong>Obsidian Sync not pulling files after setup</strong></summary>

`OBSIDIAN_AUTOSTART_SYNC` starts continuous sync, but it does not do an initial pull if the vault is empty. After running `setup`, do a one-time manual sync:

```bash
docker compose exec obsidian-headless ob sync --path /vault
```

Then set `OBSIDIAN_AUTOSTART_SYNC=true` in `.env` and restart.

</details>

<details>
<summary><strong>Triggering a redeploy after updating a secret</strong></summary>

Go to **Actions > Deploy > Run workflow**, or push an empty commit:

```bash
git commit --allow-empty -m "redeploy" && git push
```

</details>

<details>
<summary><strong>Can't find the /claim token in the install output</strong></summary>

The token is printed by takopi to its container logs. Find the most recent one:

```bash
docker compose logs takopi | grep '/claim '
```

Send the printed `/claim <token>` command to your bot in Telegram. The bot replies with confirmation and persists the bound chat ID. The installer wizard auto-extracts this for you on fresh runs.

</details>

<details>
<summary><strong>SSH "i/o timeout" from GitHub Actions deploy</strong></summary>

Means the deploy job can't reach your VPS on port 22. Check, in order:

1. `VPS_HOST` secret has the right IP (VPSes get new IPs on rebuild).
2. The VPS is up: `ping <VPS_IP>` from your machine.
3. UFW or the provider's firewall isn't blocking inbound 22.
4. The `VPS_SSH_KEY` matches a public key in `~/.ssh/authorized_keys` on the VPS.

See [docs/auto-deploy.md](auto-deploy.md) for the full setup.

</details>
