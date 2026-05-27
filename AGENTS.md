# newst-enhanced

Enhanced Newsticker: async feed download, SQLite cache,
streaming pager-based plainview.

## File Layout

```
.
├── CMakeLists.txt                 — builds pager (C++17)
├── README.md
├── AGENTS.md
├── newst-jsonrpc.el               — pager-based plainview (entry point)
├── newst-async-net.el             — concurrent feed download queue
├── newst-sql.el                   — SQLite cache backend
├── src/
│   ├── pager.cpp                  — main(), JSON-RPC registration
│   ├── db.h / db.cpp              — DatabaseManager (RAII, pre-fetch)
│   └── utf8.h / utf8.cpp          — sanitize_utf8
├── deps/
│   └── emacs-stdio-jsonrpc/       — JSON-RPC 2.0 stdio transport
│       ├── emacs-stdio-jsonrpc.el — Elisp side
│       ├── include/jsonrpc.hpp    — C++ Conn class
│       └── CMakeLists.txt
├── include/                       — json.hpp (nlohmann)
└── test/
    └── test-emacs-stdio-jsonrpc-newsticker-sqlite.el
```

## Components

### C++ — `pager` binary

JSON-RPC 2.0 server over stdio. Reads from the same SQLite database
that `newst-sql` writes to.

| Method       | Params                         | Returns                           |
|--------------|--------------------------------|-----------------------------------|
| `open`       | `{path: string}`               | `true`                            |
| `list_feeds` | `{}`                           | `[{name, count}]`                 |
| `get_page`   | `{feed, offset?, limit?}`      | `{items, total, offset, count}`   |
| `exit`       | `{}`                           | notification                      |

Key implementation:
- **`COUNT(*) OVER() AS total`** — single round-trip for pagination
- **`StmtGuard`** — RAII wrapper for `sqlite3_stmt` (auto-finalize)
- **Parallel pre-fetch** — `std::async` loads next page in background
- **Sleep-based main loop** (50ms) — reader thread uses `poll(STDIN_FILENO, 100ms)`
  internally; pipe-based waker hit `std::cin`/`poll()` buffering interaction

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

### `newst-jsonrpc.el` — Streaming pager plainview

The user-facing entry point. Installs `:around` advice on:

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
- **LRU page cache** (20 entries) — previously viewed pages restore instantly

**Lazy pager start** — first `newsticker-plainview` call starts the `pager`
subprocess automatically. Binary auto-detected relative to load directory
(or set `newst-jsonrpc-pager-path` explicitly).

**Load-path auto-setup** — when loaded via `load-file` or `emacs -l`,
adds source directory and `deps/emacs-stdio-jsonrpc/` to `load-path`.

## Dependency Chain

```
(require 'newst-jsonrpc)
  → (require 'newst-async-net)
      → (require 'newst-sql)
          → (require 'sqlite)        ; built-in
  → (require 'jsonrpc)               ; built-in
  → (require 'emacs-stdio-jsonrpc)   ; bundled in deps/
```

## Build

```sh
cmake -B build
cmake --build build
```

No new dependencies beyond sqlite3 headers and emacs-stdio-jsonrpc (bundled).

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
