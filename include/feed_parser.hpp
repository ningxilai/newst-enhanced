#pragma once

#include <string>
#include <vector>
#include <optional>
#include <ostream>

namespace jsonrpc {

struct FeedItem {
    std::string title;
    std::string description;
    std::string link;
    std::string pub_date;
    std::string guid;
};

struct FeedResult {
    std::string title;
    std::string description;
    std::string link;
    std::string language;
    std::vector<FeedItem> items;
};

// Parse RSS 2.0 or Atom XML. Returns nullopt on failure.
// xml: raw XML data (UTF-8 or ASCII)
// err: if non-null, receives a human-readable error message
std::optional<FeedResult> parse_feed(const std::string& xml, std::string* err = nullptr);

// Strip HTML tags from a string, returning plain text.
// Uses libxml2's HTML parser to handle real-world HTML fragments.
std::string strip_html(const std::string& html);

// Initialize libxml2 (call once at program start).
void init_feed_parser();

// Cleanup libxml2 (call once at program exit).
void cleanup_feed_parser();

} // namespace jsonrpc
