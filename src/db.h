#pragma once
#include <string>
#include <optional>
#include <memory>
#include <mutex>
#include <future>
#include <sqlite3.h>
#include "json.hpp"

struct PageResult {
    nlohmann::json items;
    int total = 0;
};

// RAII guard for sqlite3_stmt — auto-finalize on destruction.
struct StmtGuard {
    sqlite3_stmt* stmt = nullptr;
    ~StmtGuard() { if (stmt) sqlite3_finalize(stmt); }
    StmtGuard(const StmtGuard&) = delete;
    StmtGuard& operator=(const StmtGuard&) = delete;
    StmtGuard() = default;
    explicit StmtGuard(sqlite3_stmt* s) : stmt(s) {}
};

class DatabaseManager {
public:
    explicit DatabaseManager(const std::string& path);
    ~DatabaseManager();

    DatabaseManager(const DatabaseManager&) = delete;
    DatabaseManager& operator=(const DatabaseManager&) = delete;

    nlohmann::json list_feeds();
    PageResult get_page(const std::string& feed, int offset, int limit);

    // Parallel pre-fetch: start background load of next page.
    void prefetch_page(const std::string& feed, int offset, int limit);
    std::optional<PageResult> consume_prefetched();

private:
    sqlite3* db_ = nullptr;

    std::mutex prefetch_mutex_;
    std::optional<PageResult> prefetched_;
    std::future<void> prefetch_future_;

    PageResult do_get_page(const std::string& feed, int offset, int limit);
};
