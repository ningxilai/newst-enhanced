# newst-enhanced

Enhanced Newsticker: adaptive, high-throughput feed handling with a stock-like experience under light load.

## Quick start

```elisp
(require 'newsticker)
(require 'newst-jsonrpc)
```

Then:

```text
M-x newsticker-start RET
M-x newsticker-plainview RET
```

## What it does

`newst-enhanced` keeps the bare `newsticker` feel in normal use, but automatically scales up when feed count, latency, or failures increase.

- Light load: stays close to stock `newsticker`
- Heavy load: raises concurrency, page size, and trimming as needed
- Safe by default: global hard cap + per-host cap + explicit user overrides
- Resilient: corrupt `cache.db` is backed up and rebuilt from legacy cache files

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

Disable autoscale if needed:

```elisp
(setq newst-async-net-auto-scale-enabled nil)
(setq newst-jsonrpc-auto-scale-enabled nil)
```

## Files

- `newst-jsonrpc.el` — streaming plainview reader
- `newst-async-net.el` — adaptive async fetch queue
- `newst-sql.el` — SQLite cache and recovery layer

## Design goal

This package is intentionally adaptive by default: it preserves the original experience under light load and keeps large feed sets usable under heavier load without sacrificing safety.
