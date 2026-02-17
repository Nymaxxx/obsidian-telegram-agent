# Pipeline: от голосового в Telegram до Pull Request

Полный путь задачи через систему — от момента, когда ты нажал кнопку записи,
до готового PR на GitHub.

---

## Пример

Ты записываешь голосовое в Telegram:

> "В бэкенде надо добавить эндпоинт для экспорта пользователей в CSV,
> чтобы можно было скачать файл по ссылке"

---

## Шаг 1: Telegram принимает голосовое

```
Ты (Telegram) ──[voice .ogg]──> Telegram Bot API
```

Telegram сохраняет аудиофайл на своих серверах и отправляет событие
`voice` боту через long polling.

**Где:** Telegram Cloud -> Takopi (внутри Docker-контейнера на хомлабе)

---

## Шаг 2: Takopi скачивает и транскрибирует

```
Takopi ──[download .ogg]──> Telegram API
Takopi ──[.ogg audio]──> OpenAI Whisper API (или локальный сервер)
Whisper ──[text]──> Takopi
```

Takopi получает событие, видит что это голосовое, скачивает файл
и отправляет на транскрибацию.

**Модель:** `gpt-4o-mini-transcribe` (облако) или `whisper-1` (self-hosted)

**Результат:** текстовая строка, например:
`"[voice transcript] /back В бэкенде надо добавить эндпоинт для экспорта пользователей в CSV, чтобы можно было скачать файл по ссылке"`

Takopi добавляет префикс `[voice transcript]`, чтобы агент знал,
что это расшифровка голоса (может содержать неточности).

---

## Шаг 3: Takopi маршрутизирует команду

```
Takopi парсит: /back <текст задачи>
       ↓
Проект: back → рабочая директория /work/repos/back
Движок: claude (default_engine)
```

Takopi видит директиву `/back` и понимает:
- Нужно работать в проекте `back` (зарегистрирован при старте через `takopi init`)
- Рабочая директория: `/work/repos/back`
- Текст задачи передаётся Claude Code CLI

---

## Шаг 4: Claude Code CLI запускается

```
Takopi ──[запуск]──> claude --model claude-opus-4-6
                     рабочая директория: /work/repos/back
                     инструменты: Bash, Read, Edit, Write
```

Claude Code CLI стартует в контексте репозитория.
Первое, что он делает — читает `CLAUDE.md` из корня проекта.

---

## Шаг 5: Агент проверяет Tasks

```
Claude Code: TaskList
       ↓
Диск: ~/.claude/tasks/ (list_id: takopi-homelab)
       ↓
Результат: 0 pending tasks (или список незавершённых с прошлого раза)
```

Агент смотрит — нет ли незавершённой работы с предыдущих сессий.
Если есть, сначала разбирается с ней. Если нет — переходит к новой задаче.

---

## Шаг 6: Агент создаёт план (Tasks)

```
Claude Code: TaskCreate "add GET /api/users/export endpoint"
Claude Code: TaskCreate "implement CSV generation from User model"
Claude Code: TaskCreate "add tests for export endpoint"
Claude Code: TaskCreate "open PR" (blockedBy: все предыдущие)
```

Сложная задача разбивается на подзадачи с зависимостями.
Tasks сохраняются на диск — если сессия оборвётся, план не потеряется.

---

## Шаг 7: Агент исследует кодовую базу

```
Claude Code: Read README.md
Claude Code: Bash "find . -type f -name '*.py' | head -30"
Claude Code: Read src/api/routes.py
Claude Code: Read src/models/user.py
Claude Code: Bash "git log --oneline -10"
```

Агент ориентируется: какой фреймворк, где роуты, как выглядит модель User,
какие конвенции в коммитах.

---

## Шаг 8: Агент пишет код

```
Claude Code: TaskUpdate "add endpoint" → in_progress
Claude Code: Bash "git checkout -b feat/export-users-csv"
Claude Code: Edit src/api/routes.py      ← добавляет эндпоинт
Claude Code: Edit src/services/export.py  ← CSV-генерация
Claude Code: TaskUpdate "add endpoint" → completed
Claude Code: TaskUpdate "CSV generation" → completed
```

Агент создаёт ветку, пишет код, обновляет статусы задач по мере продвижения.

---

## Шаг 9: Агент прогоняет тесты

```
Claude Code: Edit tests/test_export.py  ← новые тесты
Claude Code: Bash "pytest -q"
       ↓
   tests/test_export.py::test_csv_export PASSED
   tests/test_export.py::test_empty_export PASSED
   24 passed in 1.2s
```

Агент добавляет тесты, запускает весь тест-сьют.
Если что-то падает — чинит до коммита.

---

## Шаг 10: Агент коммитит и открывает PR

```
Claude Code: Bash "git add src/api/routes.py src/services/export.py tests/test_export.py"
Claude Code: Bash "git commit -m 'feat: add CSV export endpoint for users'"
Claude Code: Bash "git push -u origin HEAD"
Claude Code: Bash "gh pr create --fill"
       ↓
   https://github.com/myorg/backend/pull/42
```

Агент коммитит с конвенциональным сообщением, пушит ветку,
создаёт Pull Request через GitHub CLI.

---

## Шаг 11: Агент отчитывается в Telegram

```
Claude Code ──[результат]──> Takopi ──[сообщение]──> Telegram

"Done! Created PR: https://github.com/myorg/backend/pull/42

Changes:
- Added GET /api/users/export endpoint
- CSV generation from User model with all fields
- 2 new tests

Tasks completed: 4/4"
```

Ты получаешь сообщение в Telegram с ссылкой на PR и описанием что было сделано.

---

## Шаг 12: Tasks обновлены

```
~/.claude/tasks/takopi-homelab:
  ✅ add GET /api/users/export endpoint
  ✅ implement CSV generation from User model
  ✅ add tests for export endpoint
  ✅ open PR → github.com/myorg/backend/pull/42
```

Все задачи завершены и сохранены на диск.
При следующем запуске агент увидит чистый список.

---

## Визуальная схема

```
┌──────────┐   voice    ┌──────────┐   .ogg     ┌─────────────┐
│ Telegram │ ─────────> │  Takopi  │ ────────> │   Whisper   │
│ (ты)     │            │ (бот)    │ <──────── │   (STT)     │
└──────────┘            └────┬─────┘   text     └─────────────┘
                             │
                    парсит /back + текст
                             │
                      ┌──────▼──────┐
                      │ Claude Code │
                      │    CLI      │
                      └──┬───┬───┬──┘
                         │   │   │
              ┌──────────┘   │   └──────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │  Tasks   │  │   Repo   │  │ Anthropic│
        │(на диске)│  │ /work/   │  │   API    │
        │~/.claude/│  │  repos/  │  │(мозги LLM│
        │ tasks/   │  │  back/   │  │          │
        └──────────┘  └────┬─────┘  └──────────┘
                           │
                    git push + gh pr create
                           │
                      ┌────▼─────┐
                      │  GitHub  │
                      │  PR #42  │
                      └────┬─────┘
                           │
                    ссылка на PR
                           │
                      ┌────▼─────┐
                      │ Telegram │
                      │ (тебе)  │
                      └──────────┘
```

---

## Сетевые вызовы (все outbound, никакого inbound)

| Направление | Протокол | Назначение |
|-------------|----------|------------|
| Контейнер → Telegram API | HTTPS | Long polling + отправка сообщений |
| Контейнер → OpenAI API | HTTPS | Транскрибация голоса (Whisper) |
| Контейнер → Anthropic API | HTTPS | Claude Code (генерация кода) |
| Контейнер → GitHub API | HTTPS | git push, gh pr create |

Никакие входящие порты не нужны. Весь трафик исходящий.

---

## Тайминг (примерный)

| Этап | Время |
|------|-------|
| Telegram → Takopi (event) | ~100ms |
| Транскрибация (Whisper) | 1-3 сек |
| Маршрутизация Takopi | ~50ms |
| Claude Code: exploration | 10-30 сек |
| Claude Code: coding + tests | 1-5 мин |
| git push + PR create | 5-10 сек |
| Ответ в Telegram | ~100ms |
| **Итого** | **~2-6 мин** |

---

## Что если сессия оборвалась?

1. Tasks сохранены на диск (`claude_state` volume)
2. Код в ветке — уже запушен или лежит локально (`repos` volume)
3. При следующем сообщении агент запускает `TaskList`, видит незавершённые задачи
4. Продолжает с того места, где остановился

Ничего не теряется.
