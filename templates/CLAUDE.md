# Agent Rules

## Git Workflow (PR-first)

- **Never push to `main` directly.**
- Always:
  1. Create a branch: `feat/<short>` or `fix/<short>`
  2. Run tests/linters if present
  3. Commit with a clear, conventional message (e.g. `feat: add user auth`, `fix: null check`)
  4. Open a Pull Request via `gh pr create --fill`
- Prefer minimal, reviewable diffs.
- If uncertain about behavior, add or adjust tests first.

## Code Quality

- Follow existing code style and conventions in the project.
- Do not introduce new dependencies without a clear reason.
- Keep functions small and focused.
- Add comments only for non-obvious logic; do not over-comment.

## Safety

- Never commit secrets, tokens, API keys, or credentials.
- Never delete data or files without explicit instruction.
- Never run destructive commands (`rm -rf`, `DROP TABLE`, `git push --force`) without confirmation.
- If a task is ambiguous, ask for clarification instead of guessing.

## Testing

- Run existing tests before submitting changes: `pytest -q` / `npm test` / project-specific command.
- If adding new functionality, add corresponding tests.
- If fixing a bug, add a regression test when possible.

## Available Tools

- `git status`, `git diff`, `git checkout -b ...`, `git commit -am ...`
- `gh pr create --fill`, `gh pr list`, `gh pr view`
- `pytest -q` / `npm test` / project-specific test runner
- Standard shell utilities: `grep`, `find`, `curl`, `jq`, etc.
