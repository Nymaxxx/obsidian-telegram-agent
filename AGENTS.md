# Vault editing rules

This repository is a local-first Obsidian vault controlled by Takopi from Telegram.

## Primary rules
- Treat `/vault` as the source of truth.
- Never edit `.obsidian/` unless the user explicitly asks.
- Prefer creating new notes in `Inbox/` unless a destination folder is clearly specified.
- Do not delete notes without an explicit user request.
- Avoid renaming or moving notes unless the user explicitly asks.
- For summaries, prefer creating `_summary.md` files rather than overwriting existing notes.
- Preserve existing frontmatter when updating a note.
- Keep note names human-readable and stable.

## Suggested capture flow
- Quick ideas → `Inbox/`
- Ongoing work → `Projects/`
- Time-based notes → `Daily/`

## Editing style
- Keep Markdown clean and Obsidian-friendly.
- Prefer headings, bullet points, and links over long paragraphs.
- When appending to an existing note, place new content under the most relevant heading.
