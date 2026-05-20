#define DOCTEST_CONFIG_IMPLEMENT
#include "doctest.h"
#include "feed_parser.hpp"
#include <cstring>

using namespace jsonrpc;

// Real TechCrunch RSS feed (simplified, actual content)
const auto TECHCRUNCH_RSS = R"(<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>TechCrunch</title>
    <link>https://techcrunch.com</link>
    <description>Startup and Technology News</description>
    <language>en</language>
    <item>
      <title>AI Startup Raises $500M</title>
      <link>https://techcrunch.com/ai-startup-500m</link>
      <description>Company X has raised $500 million in Series D funding.</description>
      <pubDate>Mon, 18 May 2026 14:30:00 +0000</pubDate>
      <guid>https://techcrunch.com/ai-startup-500m</guid>
    </item>
    <item>
      <title>New Programming Language Debuts</title>
      <link>https://techcrunch.com/new-lang</link>
      <description>A brand new systems programming language was announced today.</description>
      <pubDate>Mon, 18 May 2026 10:15:00 +0000</pubDate>
      <guid>https://techcrunch.com/new-lang</guid>
    </item>
  </channel>
</rss>)";

const auto ATOM_FEED = R"(<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Planet Emacs</title>
  <subtitle>Emacs community news</subtitle>
  <link href="https://planet.emacslife.com"/>
  <entry>
    <title>Emacs 30 Released</title>
    <link href="https://planet.emacslife.com/emacs-30"/>
    <summary>Emacs 30 is now available with native JSON support and improved performance.</summary>
    <published>2026-05-17T12:00:00Z</published>
    <id>urn:uuid:550e8400-e29b-41d4-a716-446655440000</id>
  </entry>
  <entry>
    <title>New Package: tree-sitter-mode</title>
    <link href="https://planet.emacslife.com/tree-sitter"/>
    <summary>Tree-sitter integration reaches stable for major modes.</summary>
    <published>2026-05-16T08:30:00Z</published>
    <id>urn:uuid:550e8400-e29b-41d4-a716-446655440001</id>
  </entry>
</feed>)";

const auto MALFORMED_XML = R"(<?xml version="1.0"?>
<rss>
  <channel>
    <item>
      <title>Unclosed tag</description>
    </item>
  </channel>
</rss>)";

const auto EMPTY_XML = "";

TEST_CASE("parse RSS 2.0 feed") {
    init_feed_parser();
    auto result = parse_feed(TECHCRUNCH_RSS);
    REQUIRE(result.has_value());

    CHECK(result->title == "TechCrunch");
    CHECK(result->link == "https://techcrunch.com");
    CHECK(result->description == "Startup and Technology News");
    CHECK(result->language == "en");

    REQUIRE(result->items.size() == 2);

    CHECK(result->items[0].title == "AI Startup Raises $500M");
    CHECK(result->items[0].link == "https://techcrunch.com/ai-startup-500m");
    CHECK(result->items[0].description == "Company X has raised $500 million in Series D funding.");
    CHECK(result->items[0].pub_date == "Mon, 18 May 2026 14:30:00 +0000");
    CHECK(result->items[0].guid == "https://techcrunch.com/ai-startup-500m");

    CHECK(result->items[1].title == "New Programming Language Debuts");
    CHECK(result->items[1].pub_date == "Mon, 18 May 2026 10:15:00 +0000");
    cleanup_feed_parser();
}

TEST_CASE("parse Atom feed") {
    init_feed_parser();
    auto result = parse_feed(ATOM_FEED);
    REQUIRE(result.has_value());

    CHECK(result->title == "Planet Emacs");
    CHECK(result->link == "https://planet.emacslife.com");
    CHECK(result->description == "Emacs community news");

    REQUIRE(result->items.size() == 2);

    CHECK(result->items[0].title == "Emacs 30 Released");
    CHECK(result->items[0].link == "https://planet.emacslife.com/emacs-30");
    CHECK(result->items[0].description == "Emacs 30 is now available with native JSON support and improved performance.");
    CHECK(result->items[0].pub_date == "2026-05-17T12:00:00Z");
    CHECK(result->items[0].guid == "urn:uuid:550e8400-e29b-41d4-a716-446655440000");

    CHECK(result->items[1].title == "New Package: tree-sitter-mode");
    cleanup_feed_parser();
}

TEST_CASE("malformed XML returns nullopt") {
    init_feed_parser();
    std::string err;
    auto result = parse_feed(MALFORMED_XML, &err);
    CHECK_FALSE(result.has_value());
    CHECK_FALSE(err.empty());
    cleanup_feed_parser();
}

TEST_CASE("empty string returns nullopt") {
    init_feed_parser();
    auto result = parse_feed(EMPTY_XML);
    CHECK_FALSE(result.has_value());
    cleanup_feed_parser();
}

TEST_CASE("unknown root element returns nullopt") {
    init_feed_parser();
    std::string err;
    auto result = parse_feed("<html><body>not a feed</body></html>", &err);
    CHECK_FALSE(result.has_value());
    CHECK(err.find("unknown root element") != std::string::npos);
    cleanup_feed_parser();
}

TEST_CASE("strip_html removes tags, keeps text") {
    CHECK(strip_html("<p>Hello <b>world</b></p>") == "Hello world");
    CHECK(strip_html("<a href=\"x\">click here</a>") == "click here");
    CHECK(strip_html("plain text") == "plain text");
    CHECK(strip_html("") == "");
    CHECK(strip_html("<p>  spaced  </p>") == "spaced");
    // Block elements get newlines
    CHECK(strip_html("<ul><li>A</li><li>B</li></ul>") == "A\nB");
    // <br> becomes newline
    CHECK(strip_html("line1<br>line2") == "line1\nline2");
    // <p> adds paragraph break
    CHECK(strip_html("<p>First</p><p>Second</p>") == "First\nSecond");
    // <script> content is stripped
    CHECK(strip_html("<p>hello</p><script>var x=1;</script>") == "hello");
    // <style> content is stripped
    CHECK(strip_html("<p>text</p><style>.foo{}</style>") == "text");
    // Malformed HTML should still produce text
    std::string result = strip_html("<p>unclosed");
    CHECK_FALSE(result.empty());
    CHECK(result.find("unclosed") != std::string::npos);
    // Multiple spaces/nested structure
    CHECK(strip_html("<div><h1>Title</h1><p>Body text</p></div>") == "Title\nBody text");
}

int main(int argc, char** argv) {
    doctest::Context ctx(argc, argv);
    return ctx.run();
}
