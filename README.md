# newst-enhanced

Enhanced Newsticker: async feed download, SQLite cache,
streaming pager-based plainview.

## Requirements

- Emacs 29.1+ (built-in `sqlite.el` for the cache backend)

No build step, no external dependencies — pure Elisp.

## File Layout

```
.
├── README.md
├── newst-jsonrpc.el               — streaming plainview (entry point)
├── newst-async-net.el             — concurrent feed download queue
└── newst-sql.el                   — SQLite cache backend
```

## Usage

Add to `init.el`:

```elisp
;; init.el
(require 'newsticker)
(require 'newst-jsonrpc)
```

Then inside Emacs:

```
M-x newsticker-start RET       ← start feed retrieval timer
M-x newsticker-plainview RET   ← open streaming reader
```

Or auto-open plainview on start:

```elisp
(add-hook 'newsticker-start-hook #'newsticker-plainview)
```

### Key bindings (plainview buffer)

These are the stock `newsticker-plainview` bindings; the pager advice
makes them stream pages instead of moving out of range:

| Key | Command |
|-----|---------|
| `n` / `TAB` | next item — appends the next page at the last item |
| `p` | previous item — prepends the previous page at the first item |
| `f` | next feed — loads that feed's first page |
| `F` | previous feed |
| `SPC` / `S-SPC` | scroll down / up |
| `q` | close buffer |

Page navigation is streaming — items are appended/prepended without
erasing the buffer.  The buffer is capped at
`newst-jsonrpc-stream-max-items`; older items are trimmed from the far
end.

### Configuration

```elisp
;; Items per fetch chunk (default: 20)
(setq newst-jsonrpc-page-size 20)

;; Max items kept in streaming buffer before trimming (default: 200)
(setq newst-jsonrpc-stream-max-items 200)

;; Truncate item descriptions to this many chars (default: 2000)
;; Set to nil for no truncation
(setq newst-jsonrpc-max-desc-length 2000)

;; Concurrent feed downloads (default: 3)
(setq newst-async-net-max-concurrent 3)

;; Per-feed download timeout in seconds (default: 15)
(setq newst-async-net-timeout 15)
```

## Architecture

```
newsticker (built-in)
  └─ newst-async-net           async feed download (url-retrieve)
       └─ newst-sql            SQLite cache (read/write)
            └─ newst-jsonrpc   streaming plainview, pages sliced
                               directly from the in-memory cache
```

Dependency chain:

```
(require 'newst-jsonrpc)
  → (require 'newst-async-net)
      → (require 'newst-sql)
          → (require 'sqlite)        ; built-in
```

No dependencies beyond Emacs 29.1 built-ins.

### `newst-sql.el` — SQLite cache

Overrides three newsticker cache functions with SQLite:

| Override target                   | Handler                |
|-----------------------------------|------------------------|
| `newsticker--cache-save`          | `newst-sql-save`       |
| `newsticker--cache-read`          | `newst-sql-read`       |
| `newsticker--cache-save-feed`     | `newst-sql-save-feed`  |

Uses Emacs 29's built-in `sqlite.el`.  Database at
`newsticker-dir/cache.db`.  Auto-migrates from the old `prin1` feed
files on first load (creates a `.sqlite-migrated` sentinel).  WAL mode
+ `synchronous=NORMAL` for concurrent read access.

### `newst-async-net.el` — Async download queue

Concurrent feed download via `url-retrieve` with timeout timers.
Queue management derived from `async-http-queue.el` by Andros Fenollosa.

- Max concurrent downloads: `newst-async-net-max-concurrent` (default 3)
- Per-feed timeout: `newst-async-net-timeout` (default 15s)
- Installs `:around` advice on `newsticker--get-news-by-url`
- Stores results into `newsticker--cache` → persisted by `newst-sql`

### `newst-jsonrpc.el` — Streaming plainview pager

The user-facing entry point.  Pages are sliced directly from the
in-memory `newsticker--cache` — no subprocess, no transport, no page
cache.  Installs `:around` advice on:

| Target function                          | Handler                           |
|------------------------------------------|-----------------------------------|
| `newsticker--buffer-insert-all-items`    | `newst-jsonrpc-advice-insert-all` |
| `newsticker-next-item`                   | `newst-jsonrpc-advice-next-item`  |
| `newsticker-previous-item`               | `newst-jsonrpc-advice-prev-item`  |
| `newsticker-next-feed`                   | `newst-jsonrpc-advice-next-feed`  |
| `newsticker-previous-feed`               | `newst-jsonrpc-advice-prev-feed`  |

**Streaming buffer model** — items are appended/prepended without
erasing:

- `n` at the last item → appends the next chunk to the buffer end
- `p` at the first item → prepends the previous chunk to the buffer start
- Buffer capped at `newst-jsonrpc-stream-max-items` (default 200),
  trims the far end

## Development

Load from source:

```elisp
M-x load-file RET /path/to/newst-jsonrpc.el RET
```

Or from the command line:

```sh
emacs -Q -L /path/to/newst-enhanced -l newst-jsonrpc.el
```

Byte-compile (0 warnings expected):

```sh
emacs -Q -L . -f batch-byte-compile newst-sql.el newst-async-net.el newst-jsonrpc.el
```

## Credits

`newst-async-net` is based on [async-http-queue.el](https://git.andros.dev/andros/async-http-queue-el)
by **Andros Fenollosa** `<hi@andros.dev>`.  The queue management,
timeout handling, and concurrent download pattern are derived from
his original work.

The pager-based offloading architecture was inspired by
[LazyCat's proposal](https://emacs-china.org/t/topic/25811) for
handling large files via external process pipelines.
