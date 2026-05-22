# newst-enhanced — C++ Pager Refactoring

## Goal
Refactor `feed_reader.cpp` into a clean, parallel `pager` binary that fully
leverages C I/O and eliminates all dead code.

## Summary of Changes

1. **Rename**: `feed_reader` → `pager` (binary, source, JSON-RPC methods stay
   compatible).
2. **Remove dead code**: empty waker, unused includes (`<thread>`, `<atomic>`),
   `g_quit` spin-loop, duplicate auto-open block.
3. **Single SQL round-trip**: replace sequential COUNT + SELECT with a single
   query using `COUNT(*) OVER() AS total`.
4. **RAII for sqlite3**: `sqlite3_stmt` auto-finalize via destructor.
5. **Parallel pre-fetch**: background thread pre-loads the next page while the
   user views the current one.
6. **Proper blocking I/O**: replace the 50ms sleep-poll with `poll()` on stdin
   so the process wakes only when data arrives.
7. **Modular file structure**: split into `pager.cpp`, `db.h`/`db.cpp`,
   `utf8.h`/`utf8.cpp`.

## File Layout After Refactoring

```
src/
  pager.cpp      — main(), JSON-RPC registration
  db.h           — DatabaseManager class (RAII, parallel pre-fetch)
  db.cpp         — DatabaseManager implementation
  utf8.h         — sanitize_utf8 declaration
  utf8.cpp       — sanitize_utf8 implementation
include/         — (existing, for jsonrpc.hpp)
deps/            — (existing, emacs-stdio-jsonrpc)
```

## JSON-RPC Interface (unchanged)

| Method | Params | Returns |
|--------|--------|---------|
| `open` | `{path: string}` | `true` |
| `list_feeds` | `{}` | `[{name, count}]` |
| `get_page` | `{feed, offset?, limit?}` | `{items, total, offset, count}` |
| `exit` | `{}` | notification |

## DatabaseManager API

```cpp
class DatabaseManager {
public:
    explicit DatabaseManager(const std::string& path);
    ~DatabaseManager();

    // Non-copyable, non-movable
    DatabaseManager(const DatabaseManager&) = delete;
    DatabaseManager& operator=(const DatabaseManager&) = delete;

    jsonrpc::json list_feeds();
    PageResult get_page(const std::string& feed, int offset, int limit);

    // Parallel pre-fetch: start background load of next page.
    // The result can be retrieved or discarded when the user turns the page.
    void prefetch_page(const std::string& feed, int offset, int limit);
    std::optional<PageResult> consume_prefetched();

private:
    sqlite3* db_ = nullptr;
    // Pre-fetch state
    std::mutex prefetch_mutex_;
    std::optional<PageResult> prefetched_;
    std::future<void> prefetch_future_;
};
```

## Key Implementation Details

### Single SQL query for get_page
```sql
SELECT title, description, link,
       time_high, time_low, time_micro, time_pico,
       age, item_pos, preformatted_contents, preformatted_title,
       extra_elements, guid,
       COUNT(*) OVER() AS total
FROM items WHERE feed_name = ?
ORDER BY item_pos LIMIT ? OFFSET ?
```

### RAII Statement Guard
```cpp
struct StmtGuard {
    sqlite3_stmt* stmt;
    ~StmtGuard() { if (stmt) sqlite3_finalize(stmt); }
    StmtGuard(const StmtGuard&) = delete;
    StmtGuard& operator=(const StmtGuard&) = delete;
};
```

### Blocking I/O with poll()
Replace `while (!g_quit) { process_queue(); sleep(50ms); }` with:
```cpp
struct pollfd pfd = {STDIN_FILENO, POLLIN, 0};
while (poll(&pfd, 1, -1) > 0) {
    server.process_queue();
    if (server.stopped()) break;
}
```

### Parallel Pre-fetch
```cpp
void DatabaseManager::prefetch_page(const std::string& feed, int offset, int limit) {
    std::lock_guard lock(prefetch_mutex_);
    if (prefetch_future_.valid()) {
        // Wait for previous pre-fetch to finish (should be fast)
        prefetch_future_.wait();
    }
    prefetch_future_ = std::async(std::launch::async, [this, feed, offset, limit] {
        auto result = do_get_page(feed, offset, limit);  // shared db_ access
        std::lock_guard lock2(prefetch_mutex_);
        prefetched_ = result;
    });
}
```

Note: SQLite in WAL mode supports concurrent reads. The `db_` handle must be
opened with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`
or use a separate read-only connection for the background thread.

## UTF-8 Sanitization
Keep the existing `sanitize_utf8()` function — it correctly handles all edge
cases. Move it to a separate `utf8.h`/`utf8.cpp` for cleanliness.

## Build
Update `CMakeLists.txt`:
- Target name changes from `feed_reader` to `pager`
- Source list: `src/pager.cpp src/db.cpp src/utf8.cpp`
- No new dependencies required beyond sqlite3 and emacs-stdio-jsonrpc
