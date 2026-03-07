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
- Write notes in the same language as the source material. Russian source → Russian note. English source → English note.

## Message handling

When a message arrives from Telegram, classify it and act accordingly:

### 1. Bare URL (message is only a link)

Fetch the page with `curl -sL <url> | head -c 100000`, extract the title and main content, then create a note:
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

When the user gives a direct instruction like "создай заметку", "суммаризируй", "перепиши", "найди" — follow the instruction as stated. Do not apply the capture-flow rules above; the user is in control.

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
