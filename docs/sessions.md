# Sessions and conversation flow

← Back to [README](../README.md)

This stack uses `session_mode = "chat"`: the bot automatically resumes the previous Claude session on every new message. Just keep sending messages, no special commands needed.

## Message flow

1. You send a message in Telegram.
2. Takopi passes it to `claude -p "your message" --resume <session_id>`.
3. Claude continues the previous conversation, remembering what it did before.
4. Takopi streams Claude's response back to Telegram.

## Useful commands

| Command | What it does |
|---------|-------------|
| `/new` | Clear the session and start fresh |
| `/cancel` | Reply to a progress message to stop the current run |

## Things to keep in mind

- **Context accumulates.** Every message adds to the conversation history. After many messages, Claude's context window fills up, responses slow down, and token costs increase. Use `/new` periodically.
- **`CLAUDE.md` is read once** at the start of each session. If you update `CLAUDE.md`, send `/new` to make Claude pick up the changes.
- **One request at a time.** Takopi serializes requests per session: if you send two messages quickly, the second waits until the first finishes.
