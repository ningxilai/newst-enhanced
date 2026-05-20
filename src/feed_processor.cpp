#include "jsonrpc.hpp"
#include "feed_parser.hpp"
#include <thread>
#include <atomic>
#include <algorithm>
#include <unistd.h>

static std::atomic<bool> g_quit{false};

int main() {
    jsonrpc::init_feed_parser();

    auto waker = []{};

    jsonrpc::Conn server(waker, std::cin, std::cout, std::cerr,
                         jsonrpc::Conn::kDefaultMaxContentLength, STDIN_FILENO);

    server.register_async_method("process_feed", [&](jsonrpc::Context ctx, const jsonrpc::json& params) {
        std::string xml = params["xml"];
        int chunk_size = params.value("chunk_size", 10);

        std::string err;
        auto result = jsonrpc::parse_feed(xml, &err);
        if (!result) {
            ctx.error(-1, "parse error: " + err);
            return;
        }

        int total_items = static_cast<int>(result->items.size());
        int total_chunks = std::max(1, (total_items + chunk_size - 1) / chunk_size);

        for (int i = 0; i < total_chunks; i++) {
            jsonrpc::json items = jsonrpc::json::array();
            int start = i * chunk_size;
            int end = std::min(start + chunk_size, total_items);

            for (int j = start; j < end; j++) {
                const auto& item = result->items[j];
                items.push_back({
                    {"title", item.title},
                    {"description", jsonrpc::strip_html(item.description)},
                    {"link", item.link},
                    {"pub_date", item.pub_date},
                    {"guid", item.guid}
                });
            }

            server.send_notification("feed_chunk", {
                {"feed_title", result->title},
                {"chunk_index", i},
                {"total_chunks", total_chunks},
                {"items", items}
            });
        }

        ctx.reply({
            {"feed_title", result->title},
            {"total_items", total_items},
            {"total_chunks", total_chunks}
        });
    });

    server.register_notification("exit", [&](const jsonrpc::json&) {
        g_quit = true;
    });

    server.start();

    while (!g_quit) {
        server.process_queue();
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    server.stop();
    jsonrpc::cleanup_feed_parser();
    return 0;
}
