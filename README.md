# newst-enhanced

Enhanced Newsticker: async feed download, SQLite cache, streaming pager-based plainview.

## Usage

```elisp
(require 'newsticker)
(require 'newst-jsonrpc)
```

Then:

```text
M-x newsticker-start RET
M-x newsticker-plainview RET
```

## Default behavior

`newst-enhanced` is designed to feel like stock `newsticker` in normal use, while scaling automatically as feeds and latency grow.

- Low-load: near-stock `newsticker` behavior
- High-load: runtime controller increases concurrency, page size, and trimming as needed
- Safety: global hard cap + per-host cap + explicit user override still win
- Recovery: if `cache.db` is corrupt, the package backs it up, rebuilds, and migrates from legacy `prin1` cache files

## Configuration

```elisp
(setq newst-async-net-auto-scale-enabled t)
(setq newst-jsonrpc-auto-scale-enabled t)

(setq newst-async-net-hardcap-global 128)
(setq newst-async-net-per-host-hardcap 8)

;; Optional explicit overrides
(setq newst-jsonrpc-page-size 20)
(setq newst-jsonrpc-stream-max-items 200)
(setq newst-jsonrpc-max-desc-length 2000)
(setq newst-async-net-max-concurrent 3)
(setq newst-async-net-timeout 15)
```

Disable adaptive behavior with:

```elisp
(setq newst-async-net-auto-scale-enabled nil)
(setq newst-jsonrpc-auto-scale-enabled nil)
```

## Files

- `newst-jsonrpc.el` — streaming reader / pager
- `newst-async-net.el` — adaptive async fetch queue
- `newst-sql.el` — SQLite cache and recovery layer

## Notes

This package is intentionally conservative at the safety boundary, while adaptive by default in the runtime path: it preserves the stock experience under light load and keeps large feed sets usable under heavier load.
