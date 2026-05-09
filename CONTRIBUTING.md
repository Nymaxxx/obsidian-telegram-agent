# Contributing

Thanks for your interest in contributing!

## How to help

- **Bug reports** — open an issue with steps to reproduce.
- **Feature ideas** — open an issue describing the use case.
- **Pull requests** — fork the repo, make your changes on a branch, and open a PR against `main`.

## Guidelines

- Keep changes focused — one PR per feature or fix.
- Follow the existing code style (shell scripts, YAML, Markdown).
- Test your changes with the dev compose override (`docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build`, or `make up-dev`) before submitting. Local builds are tagged `:dev` so they cannot collide with the `:latest` images on GHCR.
- Update the README if your change affects setup or usage.

## Local development

```bash
git clone https://github.com/Nymaxxx/obsidian-telegram-agent.git
cd obsidian-telegram-agent
cp .env.example .env
# Fill in your API keys in .env
make up-dev   # builds locally via docker-compose.dev.yml override
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
