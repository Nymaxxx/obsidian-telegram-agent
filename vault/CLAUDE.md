# Vault editing rules

This repository is a local-first Obsidian vault controlled by Takopi from Telegram.

## Vault structure (PARA)

```
/vault
├── 00 Projects/          ← active projects with a defined outcome
├── 10 Areas/
│   ├── Inbox/            ← default landing for quick captures
│   └── ...               ← your areas of responsibility
├── 20 Resources/         ← reference material by topic
├── 90 Archive/           ← OFF-LIMITS, do not access
├── .trash/               ← soft-delete destination (see Tool capabilities)
└── templates/
   └── note.md            ← template for new notes
```

> **Customize the `10 Areas/` and `20 Resources/` subfolders** to match your actual vault structure.

## Tool capabilities

You have full Bash access plus the structured file/web tools, but a system-level deny list blocks specific destructive commands. Pick the right tool for the job; reach for Bash only when no structured tool fits.

| Capability | Preferred tool |
|---|---|
| Read a file | `Read` |
| List a directory | `LS` |
| Find files by pattern | `Glob` |
| Search file contents | `Grep` |
| Create or overwrite a file | `Write` |
| Edit part of a file | `Edit` |
| Fetch a URL | `WebFetch` (preferred over `curl`) |
| Rename or move a file | `Bash` with `mv` |
| Soft-delete a file | `Bash` with `mv <file> /vault/.trash/` |
| Commit the vault | `Bash` with `git ...` |

**Commands that are blocked at the system level (your `Bash` tool calls will fail):**
- `rm`, `rmdir` — use soft-delete instead.
- `chmod`, `chown` — vault permissions are managed outside the agent.
- `dd`, `mkfs`, `shred`, `truncate` — disk-destructive ops.
- `find ... -delete`, `find ... -exec rm ...` — bulk-deletion shortcuts.
- `sudo` — not available; container is already root-equivalent within its sandbox.

The deny list catches the obvious destructive primitives but is a guard rail, not a complete sandbox: a clever shell trick (e.g. a `python -c '... os.remove(...)'` snippet, an `awk` script that overwrites a file) is technically not blocked. **Do not try to evade these restrictions.** If the operator asks for something that would require evading them, report the limitation explicitly and offer the closest legitimate action (soft-delete instead of `rm`, ask the user to run it via SSH, etc.).

## Off-limits paths

The following paths are **strictly off-limits** — never read, write, list, or reference them. Treat them as if they do not exist.

- `90 Archive/`
- `.obsidian/` — never edit unless the user explicitly asks.
- `.trash/` — write-only via the soft-delete mechanism above. Do not list, read, or restore files from it without an explicit user request.

## Primary rules
- Treat `/vault` as the source of truth and assume the user has no other backup readily at hand.
- New notes go to `10 Areas/Inbox/` by default, unless a destination folder is clearly specified.
- "Delete" means **soft-delete**: `mv <path> /vault/.trash/`. The agent has no access to `rm`. The user empties `.trash/` manually via SSH when they're sure.
- Do not soft-delete notes without an explicit, unambiguous user request. Vague instructions like "clean up", "tidy", or "remove old stuff" are NOT permission to soft-delete — ask the user to confirm specific files before moving them to `.trash/`.
- Never run `git reset --hard`, `git clean`, or any other destructive git command without explicit confirmation, even if the user's earlier message seemed to invite it.
- Prefer reversible actions: when in doubt, archive or rename rather than soft-delete.
- Avoid renaming or moving notes unless the user explicitly asks.
- For summaries, prefer creating `_summary.md` files rather than overwriting existing notes.
- Preserve existing frontmatter when updating a note.
- Keep note names human-readable and stable.
- Write notes in the same language as the source material or the user's message.

## Message handling

When a message arrives from Telegram, classify it and act accordingly:

### 1. Bare URL (message is only a link)

Fetch the page with the `WebFetch` tool (preferred over `curl`: it's structured, server-side, and doesn't go through the shell). Extract the title and main content, then create a note:
- **Location:** `10 Areas/Inbox/`
- **Filename:** article title, cleaned for filesystem (no special chars)
- **Content:**
  ```
  ---
  created: YYYY-MM-DD
  tags: []
  source: <url>
  status: inbox
  ---

  # <Article title>

  ## Summary

  <3–5 sentence summary with key takeaways as bullet points>

  ## Source

  <url>
  ```
- Reply with the note title and a one-line summary.

### 2. URL + comment (link accompanied by user text)

Same as bare URL, but:
- Use the user's comment as context to focus the summary on what they found interesting.
- Add the user's comment under a `## Context` section before the summary.
- If the comment hints at a specific folder (e.g. mentions a project name), place the note there instead of Inbox.

### 3. Quick idea or thought (short text, no URL, no explicit command)

Create a short note:
- **Location:** `10 Areas/Inbox/`
- **Filename:** derive from the first meaningful phrase (3–5 words max)
- **Content:**
  ```
  ---
  created: YYYY-MM-DD
  tags: []
  source: telegram
  status: inbox
  ---

  # <Short descriptive title>

  <The original message text, lightly formatted>
  ```
- Reply confirming the note was created with its title.

### 4. Voice message (transcribed text from Takopi)

Voice transcripts arrive as regular text prefixed or tagged by Takopi. Treat the transcript as the message body and apply the same rules:
- If the transcript contains a URL → handle as scenario 1 or 2.
- If it's a short thought → handle as scenario 3.
- If it's a longer dictation → create a note in `10 Areas/Inbox/` with the full cleaned-up transcript under `## Notes`, and add a short `## Summary` at the top.
- Clean up filler words and false starts from the transcript, but preserve the original meaning.

### 5. Explicit command (message starts with a clear instruction)

When the user gives a direct instruction like "create a note", "summarize", "rewrite", "find" — follow the instruction as stated. Do not apply the capture-flow rules above; the user is in control.

## Capture flow
- Quick ideas, voice captures → `10 Areas/Inbox/`
- Active project work → `00 Projects/<project name>/`
- Reference material → `20 Resources/<topic>/`
- General notes without a clear home → `10 Areas/Inbox/`

## Editing style
- Keep Markdown clean and Obsidian-friendly.
- Prefer headings, bullet points, and links over long paragraphs.
- When appending to an existing note, place new content under the most relevant heading.
- Use `[[wikilinks]]` for internal links between notes.
