# newst-enhanced

Enhanced Newsticker: async feed download, SQLite cache,
streaming pager-based plainview.

## File Layout

```
.
├── README.md
├── AGENTS.md
├── newst-jsonrpc.el               — streaming plainview (entry point)
├── newst-async-net.el             — concurrent feed download queue
├── newst-sql.el                   — SQLite cache backend
└── test/
    ├── test-emacs-stdio-jsonrpc-newsticker-sqlite.el
    └── test-newst-jsonrpc-paging.el
```

## Components

### `newst-sql.el` — SQLite cache

Overrides three newsticker cache functions with SQLite:

| Override target                   | Handler            |
|-----------------------------------|--------------------|
| `newsticker--cache-save`          | `newst-sql-save`   |
| `newsticker--cache-read`          | `newst-sql-read`   |
| `newsticker--cache-save-feed`     | `newst-sql-save-feed` |

Uses Emacs 29's built-in `sqlite.el`. Database at `newsticker-dir/cache.db`.
Auto-migrates from old prin1 files on first load (creates `.sqlite-migrated`
sentinel). WAL mode + synchronous=NORMAL for concurrent read access by pager.

### `newst-async-net.el` — Async download queue

Concurrent feed download via `url-retrieve` with timeout timers.
Queue management derived from `async-http-queue.el` by Andros Fenollosa.

- Max concurrent downloads: `newst-async-net-max-concurrent` (default 3)
- Per-feed timeout: `newst-async-net-timeout` (default 30s)
- Installs `:around` advice on `newsticker--get-news-by-url`
- Stores results into `newsticker--cache` → persisted by `newst-sql`

### `newst-jsonrpc.el` — Streaming plainview pager

The user-facing entry point. Pages are sliced directly from the
in-memory `newsticker--cache` — no subprocess, no transport, no page
cache. Installs `:around` advice on:

| Target function                          | Handler                                  |
|------------------------------------------|------------------------------------------|
| `newsticker--buffer-insert-all-items`    | `newst-jsonrpc-advice-insert-all`        |
| `newsticker-next-item`                   | `newst-jsonrpc-advice-next-item`         |
| `newsticker-previous-item`               | `newst-jsonrpc-advice-prev-item`         |
| `newsticker-next-feed`                   | `newst-jsonrpc-advice-next-feed`         |
| `newsticker-previous-feed`               | `newst-jsonrpc-advice-prev-feed`         |

**Streaming buffer model** — items are appended/prepended without erasing:
- "n" at last item → appends next chunk to buffer end
- "p" at first item → prepends previous chunk at buffer start
- Buffer capped at `newst-jsonrpc-stream-max-items` (default 200), trims far end

## Dependency Chain

```
(require 'newst-jsonrpc)
  → (require 'newst-async-net)
      → (require 'newst-sql)
          → (require 'sqlite)        ; built-in
```

No dependencies beyond Emacs 29.1 built-ins. No build step — pure Elisp.

## Usage

```elisp
;; init.el
(require 'newsticker)
(require 'newst-jsonrpc)
```

```
M-x newsticker-start RET
M-x newsticker-plainview RET
```

Or auto-open:

```elisp
(add-hook 'newsticker-start-hook #'newsticker-plainview)
```

## Credits

`newst-async-net` is based on [async-http-queue.el](https://git.andros.dev/andros/async-http-queue-el)
by **Andros Fenollosa** `<hi@andros.dev>`.
