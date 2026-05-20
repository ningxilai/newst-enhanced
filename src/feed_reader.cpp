#include "jsonrpc.hpp"
#include <sqlite3.h>
#include <thread>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace {
    std::atomic<bool> g_quit{false};
    sqlite3* g_db = nullptr;
}

// Replace invalid UTF-8 sequences with U+FFFD.
// Rejects overlong sequences, surrogate halves (U+D800-U+DFFF),
// and codepoints > U+10FFFF.
static std::string sanitize_utf8(const std::string& s) {
    std::string result;
    result.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = (unsigned char)s[i];
        auto repl = [&]{ result += "\xEF\xBF\xBD"; i++; };
        if (c <= 0x7F) {
            result += c; i++;
        } else if (c >= 0xC2 && c <= 0xDF && i + 1 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            if (c2 >= 0x80 && c2 <= 0xBF) {
                result += c; result += c2; i += 2;
            } else repl();
        } else if (c == 0xE0 && i + 2 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            if (c2 >= 0xA0 && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF) {
                result += c; result += c2; result += c3; i += 3;
            } else repl();
        } else if (c >= 0xE1 && c <= 0xEC && i + 2 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            if (c2 >= 0x80 && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF) {
                result += c; result += c2; result += c3; i += 3;
            } else repl();
        } else if (c == 0xED && i + 2 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            if (c2 >= 0x80 && c2 <= 0x9F && c3 >= 0x80 && c3 <= 0xBF) {
                result += c; result += c2; result += c3; i += 3;
            } else repl();
        } else if (c >= 0xEE && c <= 0xEF && i + 2 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            if (c2 >= 0x80 && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF) {
                result += c; result += c2; result += c3; i += 3;
            } else repl();
        } else if (c == 0xF0 && i + 3 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            unsigned char c4 = (unsigned char)s[i + 3];
            if (c2 >= 0x90 && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF && c4 >= 0x80 && c4 <= 0xBF) {
                result += c; result += c2; result += c3; result += c4; i += 4;
            } else repl();
        } else if (c >= 0xF1 && c <= 0xF3 && i + 3 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            unsigned char c4 = (unsigned char)s[i + 3];
            if (c2 >= 0x80 && c2 <= 0xBF && c3 >= 0x80 && c3 <= 0xBF && c4 >= 0x80 && c4 <= 0xBF) {
                result += c; result += c2; result += c3; result += c4; i += 4;
            } else repl();
        } else if (c == 0xF4 && i + 3 < s.size()) {
            unsigned char c2 = (unsigned char)s[i + 1];
            unsigned char c3 = (unsigned char)s[i + 2];
            unsigned char c4 = (unsigned char)s[i + 3];
            if (c2 >= 0x80 && c2 <= 0x8F && c3 >= 0x80 && c3 <= 0xBF && c4 >= 0x80 && c4 <= 0xBF) {
                result += c; result += c2; result += c3; result += c4; i += 4;
            } else repl();
        } else {
            repl();
        }
    }
    return result;
}

static jsonrpc::json row_to_item(sqlite3_stmt* stmt) {
    auto get_text = [&](int col) -> std::string {
        const char* s = (const char*)sqlite3_column_text(stmt, col);
        return s ? sanitize_utf8(std::string(s)) : "";
    };

    jsonrpc::json item;
    item["title"] = get_text(0);
    item["description"] = get_text(1);
    item["link"] = get_text(2);
    item["time"] = {sqlite3_column_int64(stmt, 3),
                    sqlite3_column_int64(stmt, 4),
                    sqlite3_column_int64(stmt, 5),
                    sqlite3_column_int64(stmt, 6)};
    item["age"] = get_text(7);
    item["pos"] = sqlite3_column_int(stmt, 8);
    item["preformatted_contents"] = get_text(9);
    item["preformatted_title"] = get_text(10);
    item["extra"] = get_text(11);
    item["guid"] = get_text(12);
    return item;
}

int main(int argc, char* argv[]) {
    std::string db_path;
    if (argc > 1) {
        db_path = argv[1];
    }

    auto waker = []{};

    jsonrpc::Conn server(waker, std::cin, std::cout, std::cerr,
                         jsonrpc::Conn::kDefaultMaxContentLength, STDIN_FILENO);

    server.register_method("open", [&](const jsonrpc::json& params) -> jsonrpc::json {
        std::string path = params.value("path", db_path);
        if (path.empty()) {
            throw std::runtime_error("no database path specified");
        }
        if (g_db) {
            sqlite3_close(g_db);
            g_db = nullptr;
        }
        int rc = sqlite3_open(path.c_str(), &g_db);
        if (rc != SQLITE_OK) {
            std::string msg = sqlite3_errmsg(g_db);
            sqlite3_close(g_db);
            g_db = nullptr;
            throw std::runtime_error("failed to open db: " + msg);
        }
        return true;
    });

    server.register_method("list_feeds", [&](const jsonrpc::json&) -> jsonrpc::json {
        if (!g_db) throw std::runtime_error("database not opened");
        const char* sql = "SELECT feed_name, COUNT(*) FROM items GROUP BY feed_name ORDER BY feed_name";
        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(g_db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            throw std::runtime_error(sqlite3_errmsg(g_db));
        }
        jsonrpc::json result = jsonrpc::json::array();
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            jsonrpc::json feed;
            const char* name = (const char*)sqlite3_column_text(stmt, 0);
            feed["name"] = sanitize_utf8(name ? std::string(name) : "");
            feed["count"] = sqlite3_column_int(stmt, 1);
            result.push_back(feed);
        }
        sqlite3_finalize(stmt);
        return result;
    });

    server.register_method("get_page", [&](const jsonrpc::json& params) -> jsonrpc::json {
        if (!g_db) throw std::runtime_error("database not opened");
        std::string feed_name = params["feed"];
        int offset = params.value("offset", 0);
        int limit = params.value("limit", 20);

        // Get total count for this feed
        const char* count_sql = "SELECT COUNT(*) FROM items WHERE feed_name = ?";
        sqlite3_stmt* stmt = nullptr;
        int total = 0;
        if (sqlite3_prepare_v2(g_db, count_sql, -1, &stmt, nullptr) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, feed_name.c_str(), -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                total = sqlite3_column_int(stmt, 0);
            }
            sqlite3_finalize(stmt);
            stmt = nullptr;
        }

        // Get page
        const char* page_sql =
            "SELECT title, description, link, "
            "time_high, time_low, time_micro, time_pico, "
            "age, item_pos, preformatted_contents, preformatted_title, "
            "extra_elements, guid "
            "FROM items WHERE feed_name = ? ORDER BY item_pos LIMIT ? OFFSET ?";

        if (sqlite3_prepare_v2(g_db, page_sql, -1, &stmt, nullptr) != SQLITE_OK) {
            throw std::runtime_error(sqlite3_errmsg(g_db));
        }
        sqlite3_bind_text(stmt, 1, feed_name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 2, limit);
        sqlite3_bind_int(stmt, 3, offset);

        jsonrpc::json items = jsonrpc::json::array();
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            items.push_back(row_to_item(stmt));
        }
        sqlite3_finalize(stmt);

        jsonrpc::json result;
        result["items"] = items;
        result["total"] = total;
        result["offset"] = offset;
        result["count"] = (int)items.size();
        return result;
    });

    server.register_notification("exit", [&](const jsonrpc::json&) {
        g_quit = true;
    });

    // Auto-open if path provided on command line
    if (!db_path.empty()) {
        int rc = sqlite3_open(db_path.c_str(), &g_db);
        if (rc != SQLITE_OK) {
            std::cerr << "Failed to open database: " << sqlite3_errmsg(g_db) << std::endl;
            if (g_db) sqlite3_close(g_db);
            g_db = nullptr;
        }
    }

    server.start();

    while (!g_quit) {
        server.process_queue();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    server.stop();
    if (g_db) sqlite3_close(g_db);
    return 0;
}
