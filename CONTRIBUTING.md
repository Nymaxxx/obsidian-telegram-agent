# Contributing

Thanks for your interest in contributing!

## How to help

- **Bug reports** — open an issue with steps to reproduce.
- **Feature ideas** — open an issue describing the use case.
- **Pull requests** — fork the repo, make your changes on a branch, and open a PR against `main`.

## Guidelines

- Keep changes focused — one PR per feature or fix.
- Follow the existing code style (shell scripts, YAML, Markdown).
- Test your changes with `docker compose up --build` before submitting.
- Update the README if your change affects setup or usage.

## Local development

```bash
git clone https://github.com/YOUR_USERNAME/obsidian-telegram-agent.git
cd obsidian-telegram-agent
cp .env.example .env
# Fill in your API keys in .env
docker compose up --build
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
