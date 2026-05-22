#include "jsonrpc.hpp"
#include "db.h"
#include <string>
#include <memory>
#include <chrono>
#include <thread>

int main(int argc, char* argv[]) {
    std::string db_path;
    if (argc > 1) {
        db_path = argv[1];
    }

    bool stopped = false;
    std::unique_ptr<DatabaseManager> db;

    jsonrpc::Conn server([]{
        // No-op waker: the main loop polls with a short sleep.
    }, std::cin, std::cout, std::cerr,
    jsonrpc::Conn::kDefaultMaxContentLength, STDIN_FILENO);

    server.register_method("open", [&](const jsonrpc::json& params) -> jsonrpc::json {
        std::string path = params.value("path", db_path);
        if (path.empty()) {
            throw std::runtime_error("no database path specified");
        }
        db.reset();
        db = std::make_unique<DatabaseManager>(path);
        return true;
    });

    server.register_method("list_feeds", [&](const jsonrpc::json&) -> jsonrpc::json {
        if (!db) throw std::runtime_error("database not opened");
        return db->list_feeds();
    });

    server.register_method("get_page", [&](const jsonrpc::json& params) -> jsonrpc::json {
        if (!db) throw std::runtime_error("database not opened");
        std::string feed_name = params["feed"];
        int offset = params.value("offset", 0);
        int limit = params.value("limit", 20);

        auto result = db->get_page(feed_name, offset, limit);

        // Pre-fetch the next page in background.
        int next_offset = offset + limit;
        if (next_offset < result.total) {
            db->prefetch_page(feed_name, next_offset, limit);
        }

        jsonrpc::json j;
        j["items"] = result.items;
        j["total"] = result.total;
        j["offset"] = offset;
        j["count"] = (int)result.items.size();
        return j;
    });

    server.register_notification("exit", [&](const jsonrpc::json&) {
        stopped = true;
    });

    // Auto-open if path provided on command line.
    if (!db_path.empty()) {
        try {
            db = std::make_unique<DatabaseManager>(db_path);
        } catch (const std::exception& e) {
            std::cerr << "Failed to open database: " << e.what() << std::endl;
        }
    }

    server.start();

    while (!stopped) {
        server.process_queue();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    server.stop();
    db.reset();
    return 0;
}
