#include "db.h"
#include "utf8.h"
#include <stdexcept>

DatabaseManager::DatabaseManager(const std::string& path) {
    int rc = sqlite3_open(path.c_str(), &db_);
    if (rc != SQLITE_OK) {
        std::string msg = sqlite3_errmsg(db_);
        sqlite3_close(db_);
        db_ = nullptr;
        throw std::runtime_error("failed to open db: " + msg);
    }
}

DatabaseManager::~DatabaseManager() {
    // Wait for any in-flight pre-fetch.
    if (prefetch_future_.valid()) {
        prefetch_future_.wait();
    }
    if (db_) {
        sqlite3_close(db_);
    }
}

// Helper: extract text from a column, sanitize UTF-8.
static std::string col_text(sqlite3_stmt* stmt, int col) {
    const char* s = (const char*)sqlite3_column_text(stmt, col);
    return s ? sanitize_utf8(std::string(s)) : "";
}

nlohmann::json DatabaseManager::list_feeds() {
    const char* sql = "SELECT feed_name, COUNT(*) FROM items "
                      "GROUP BY feed_name ORDER BY feed_name";
    StmtGuard g;
    if (sqlite3_prepare_v2(db_, sql, -1, &g.stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(sqlite3_errmsg(db_));
    }
    nlohmann::json result = nlohmann::json::array();
    while (sqlite3_step(g.stmt) == SQLITE_ROW) {
        nlohmann::json feed;
        feed["name"] = col_text(g.stmt, 0);
        feed["count"] = sqlite3_column_int(g.stmt, 1);
        result.push_back(feed);
    }
    return result;
}

PageResult DatabaseManager::do_get_page(const std::string& feed,
                                        int offset, int limit) {
    const char* sql =
        "SELECT title, description, link, "
        "time_high, time_low, time_micro, time_pico, "
        "age, item_pos, preformatted_contents, preformatted_title, "
        "extra_elements, guid, "
        "COUNT(*) OVER() AS total "
        "FROM items WHERE feed_name = ? "
        "ORDER BY item_pos LIMIT ? OFFSET ?";

    StmtGuard g;
    if (sqlite3_prepare_v2(db_, sql, -1, &g.stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error(sqlite3_errmsg(db_));
    }
    sqlite3_bind_text(g.stmt, 1, feed.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(g.stmt, 2, limit);
    sqlite3_bind_int(g.stmt, 3, offset);

    PageResult result;
    result.items = nlohmann::json::array();
    int total = 0;
    int count = 0;

    while (sqlite3_step(g.stmt) == SQLITE_ROW) {
        nlohmann::json item;
        item["title"] = col_text(g.stmt, 0);
        item["description"] = col_text(g.stmt, 1);
        item["link"] = col_text(g.stmt, 2);
        item["time"] = {sqlite3_column_int64(g.stmt, 3),
                        sqlite3_column_int64(g.stmt, 4),
                        sqlite3_column_int64(g.stmt, 5),
                        sqlite3_column_int64(g.stmt, 6)};
        item["age"] = col_text(g.stmt, 7);
        item["pos"] = sqlite3_column_int(g.stmt, 8);
        item["preformatted_contents"] = col_text(g.stmt, 9);
        item["preformatted_title"] = col_text(g.stmt, 10);
        item["extra"] = col_text(g.stmt, 11);
        item["guid"] = col_text(g.stmt, 12);
        result.items.push_back(item);
        total = sqlite3_column_int(g.stmt, 13);
        ++count;
    }

    result.total = (count > 0) ? total : 0;
    return result;
}

PageResult DatabaseManager::get_page(const std::string& feed,
                                     int offset, int limit) {
    // Only consume the pre-fetched page on exact param match.
    // A mismatch (feed switch, jump) discards it and fetches fresh —
    // otherwise the caller would silently receive the wrong page.
    {
        std::lock_guard<std::mutex> lock(prefetch_mutex_);
        if (prefetched_.has_value()) {
            PageRequest want{feed, offset, limit};
            if (prefetched_->request == want) {
                auto result = std::move(prefetched_->result);
                prefetched_.reset();
                return result;
            }
            prefetched_.reset();
        }
    }
    return do_get_page(feed, offset, limit);
}

void DatabaseManager::prefetch_page(const std::string& feed,
                                     int offset, int limit) {
    std::lock_guard<std::mutex> lock(prefetch_mutex_);
    if (prefetch_future_.valid()) {
        prefetch_future_.wait();
    }
    // Capture a copy of feed string and ints for the async lambda.
    prefetch_future_ = std::async(std::launch::async,
        [this, feed, offset, limit] {
            auto result = do_get_page(feed, offset, limit);
            std::lock_guard<std::mutex> lock2(prefetch_mutex_);
            prefetched_ = PrefetchedPage{{feed, offset, limit}, result};
        });
}

std::optional<PageResult> DatabaseManager::consume_prefetched() {
    std::lock_guard<std::mutex> lock(prefetch_mutex_);
    if (!prefetched_.has_value()) {
        return std::nullopt;
    }
    auto result = std::move(prefetched_->result);
    prefetched_.reset();
    return result;
}
