# Vault editing rules

This repository is a local-first Obsidian vault controlled by Takopi from Telegram.

## Vault structure (PARA)

```
/vault
├── 00 Projects/          ← active projects (ABAGY, CAD Copilot, etc.)
├── 10 Areas/
│   ├── Inbox/            ← default landing for quick captures
│   ├── Todo/
│   │   ├── Daily notes/  ← daily journal entries
│   │   ├── Long goals/
│   │   └── Short goals/
│   ├── База знаний ЕКТ/
│   ├── Общие заметки/
│   └── Планы на 2026/
├── 20 Resources/         ← reference material (AI Tools, Education, etc.)
├── 90 Archive/           ← inactive notes and attachments
└── templates/
   └── note.md            ← template for new notes
```

## Primary rules
- Treat `/vault` as the source of truth.
- Never edit `.obsidian/` unless the user explicitly asks.
- New notes go to `10 Areas/Inbox/` by default, unless a destination folder is clearly specified.
- Do not delete notes without an explicit user request.
- Avoid renaming or moving notes unless the user explicitly asks.
- For summaries, prefer creating `_summary.md` files rather than overwriting existing notes.
- Preserve existing frontmatter when updating a note.
- Keep note names human-readable and stable.

## Capture flow
- Quick ideas, voice captures → `10 Areas/Inbox/`
- Active project work → `00 Projects/<project name>/`
- Daily journal → `10 Areas/Todo/Daily notes/`
- Goals and tasks → `10 Areas/Todo/Short goals/` or `10 Areas/Todo/Long goals/`
- Reference material → `20 Resources/<topic>/`
- General notes without a clear home → `10 Areas/Общие заметки/`

## Editing style
- Keep Markdown clean and Obsidian-friendly.
- Prefer headings, bullet points, and links over long paragraphs.
- When appending to an existing note, place new content under the most relevant heading.
- Use `[[wikilinks]]` for internal links between notes.
