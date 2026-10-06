# newst-enhanced

Enhanced Newsticker with async feed download, SQLite cache,
and streaming pager-based plainview.

## Requirements

- Emacs 29.1+ (built-in `sqlite.el` for the cache backend)

No build step, no external dependencies.

## Usage

Add to `init.el`:

```elisp
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

| Key | Command |
|-----|---------|
| `n` | next item (loads next page at end) |
| `p` | previous item (loads previous page at start) |
| `N` | next feed |
| `P` | previous feed |
| `q` | close buffer |

Page navigation is streaming — items are appended/prepended
without erasing the buffer. Previously viewed pages are cached
(LRU, 20 pages) for instant re-visit.

### Configuration

```elisp
;; Items per fetch chunk (default: 20)
(setq newst-jsonrpc-page-size 20)

;; Max items kept in streaming buffer before trimming (default: 200)
(setq newst-jsonrpc-stream-max-items 200)

;; Truncate item descriptions to this many chars (default: 2000)
;; Set to nil for no truncation
(setq newst-jsonrpc-max-desc-length 2000)
```

## Architecture

```
newsticker (built-in)
  └─ newst-async-net           async feed download (url-retrieve)
       └─ newst-sql            SQLite cache (read/write)
            └─ newst-jsonrpc   streaming plainview, pages sliced
                               directly from the in-memory cache
```

- `newst-async-net` — concurrent feed download via `url-retrieve`,
  stores results in SQLite via newst-sql
- `newst-sql` — overrides newsticker cache save/read with SQLite
- `newst-jsonrpc` — around-advice on `newsticker--buffer-insert-all-items`
  and navigation functions; streaming append/prepend pager

## Development

Load from source:

```elisp
M-x load-file RET /path/to/newst-jsonrpc.el RET
```

Or from the command line:

```sh
emacs -Q -l /path/to/newst-jsonrpc.el
```

Both automatically add `deps/emacs-stdio-jsonrpc/` to `load-path`.

## Credits

`newst-async-net` is based on [async-http-queue.el](https://git.andros.dev/andros/async-http-queue-el)
by **Andros Fenollosa** `<hi@andros.dev>`.  The queue management,
timeout handling, and concurrent download pattern are derived from
his original work.

The pager-based offloading architecture was inspired by
[LazyCat's proposal](https://emacs-china.org/t/topic/25811) for
handling large files via external process pipelines.
