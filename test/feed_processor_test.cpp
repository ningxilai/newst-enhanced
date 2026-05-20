#define DOCTEST_CONFIG_IMPLEMENT
#include "doctest.h"
#include "jsonrpc.hpp"
#include <array>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <thread>
#include <chrono>
#include <sys/wait.h>

using namespace jsonrpc;

// Build a Content-Length framed message.
std::string frame(const std::string& body) {
    return "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
}

// Read one framed message from fd.
// Returns empty string on EOF/error.
std::string read_frame(int fd) {
    std::string header;
    char c;
    // Read until \r\n\r\n
    while (true) {
        ssize_t n = read(fd, &c, 1);
        if (n <= 0) return "";
        header += c;
        if (header.size() >= 4
            && header.substr(header.size() - 4) == "\r\n\r\n") {
            break;
        }
    }

    // Parse Content-Length
    int len = 0;
    auto pos = header.find("Content-Length:");
    if (pos != std::string::npos) {
        auto start = header.find_first_of("0123456789", pos + 15);
        if (start != std::string::npos) {
            len = std::stoi(header.substr(start));
        }
    }
    if (len <= 0) return "";

    std::string body;
    body.resize(len);
    size_t total = 0;
    while (total < static_cast<size_t>(len)) {
        ssize_t n = read(fd, &body[0] + total, len - static_cast<int>(total));
        if (n <= 0) return "";
        total += n;
    }
    return body;
}

TEST_CASE("feed_processor parses RSS and sends chunks") {
    int to_child[2], from_child[2];
    REQUIRE(pipe(to_child) == 0);
    REQUIRE(pipe(from_child) == 0);

    pid_t pid = fork();
    REQUIRE_GE(pid, 0);

    if (pid == 0) {
        // Child: feed_processor
        dup2(to_child[0], STDIN_FILENO);
        dup2(from_child[1], STDOUT_FILENO);
        close(to_child[0]);
        close(to_child[1]);
        close(from_child[0]);
        close(from_child[1]);
        execl(FEED_PROCESSOR_PATH, "feed_processor", nullptr);
        _exit(1);
    }

    close(to_child[0]);
    close(from_child[1]);

    // Give child time to start
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // Send process_feed request
    json req = {
        {"jsonrpc", "2.0"},
        {"id", 1},
        {"method", "process_feed"},
        {"params", {
            {"xml", R"(<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Test Feed</title>
    <link>http://example.com</link>
    <description>A test</description>
    <item>
      <title>Item 1</title>
      <link>http://example.com/1</link>
      <description>First</description>
      <pubDate>Mon, 18 May 2026 00:00:00 +0000</pubDate>
      <guid>guid-1</guid>
    </item>
    <item>
      <title>Item 2</title>
      <link>http://example.com/2</link>
      <description>Second</description>
      <pubDate>Mon, 18 May 2026 01:00:00 +0000</pubDate>
      <guid>guid-2</guid>
    </item>
    <item>
      <title>Item 3</title>
      <link>http://example.com/3</link>
      <description>Third</description>
      <pubDate>Mon, 18 May 2026 02:00:00 +0000</pubDate>
      <guid>guid-3</guid>
    </item>
  </channel>
</rss>)"
            },
            {"chunk_size", 2}
        }}
    };
    std::string msg = frame(req.dump());
    (void)write(to_child[1], msg.data(), msg.size());

    // Read responses: expect 2 notifications + 1 response
    std::vector<std::string> messages;
    for (int i = 0; i < 3; i++) {
        auto body = read_frame(from_child[0]);
        REQUIRE_FALSE(body.empty());
        messages.push_back(body);
    }

    // Parse all messages
    json msg0 = json::parse(messages[0]);
    json msg1 = json::parse(messages[1]);
    json msg2 = json::parse(messages[2]);

    // Both chunk notifications have method "feed_chunk"
    // (order might vary but let's check by method field)
    json* chunk1 = nullptr;
    json* chunk2 = nullptr;
    json* response = nullptr;

    for (auto* m : {&msg0, &msg1, &msg2}) {
        if (m->contains("method") && (*m)["method"] == "feed_chunk") {
            if (!chunk1) chunk1 = m;
            else chunk2 = m;
        }
        if (m->contains("id") && m->contains("result")) {
            response = m;
        }
    }

    REQUIRE(chunk1 != nullptr);
    REQUIRE(chunk2 != nullptr);
    REQUIRE(response != nullptr);

    CHECK((*response)["result"]["feed_title"] == "Test Feed");
    CHECK((*response)["result"]["total_items"] == 3);
    CHECK((*response)["result"]["total_chunks"] == 2);

    // Check chunk sizes
    CHECK((*chunk1)["params"]["items"].size() == 2);
    CHECK((*chunk2)["params"]["items"].size() == 1);
    CHECK((*chunk1)["params"]["feed_title"] == "Test Feed");
    CHECK((*chunk2)["params"]["feed_title"] == "Test Feed");

    // Send exit notification
    json exit_msg = {
        {"jsonrpc", "2.0"},
        {"method", "exit"}
    };
    msg = frame(exit_msg.dump());
    (void)write(to_child[1], msg.data(), msg.size());
    close(to_child[1]);  // Close write end so reader thread sees EOF

    int status;
    waitpid(pid, &status, 0);
    CHECK(WIFEXITED(status));

    close(from_child[0]);
}

int main(int argc, char** argv) {
    doctest::Context ctx(argc, argv);
    return ctx.run();
}
