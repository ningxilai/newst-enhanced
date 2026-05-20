#include "feed_parser.hpp"
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/HTMLparser.h>
#include <cstring>

namespace jsonrpc {
namespace {

void set_err(std::string* err, const char* msg) {
    if (err) *err = msg;
}

std::string text_content(xmlNode* node) {
    if (!node) return "";
    xmlChar* txt = xmlNodeGetContent(node);
    if (!txt) return "";
    std::string s(reinterpret_cast<const char*>(txt));
    xmlFree(txt);
    size_t start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

xmlNode* child_elem(xmlNode* parent, const char* name) {
    if (!parent) return nullptr;
    for (xmlNode* cur = parent->children; cur; cur = cur->next) {
        if (cur->type == XML_ELEMENT_NODE
            && xmlStrEqual(cur->name, reinterpret_cast<const xmlChar*>(name))) {
            return cur;
        }
    }
    return nullptr;
}

std::string child_text(xmlNode* parent, const char* name) {
    return text_content(child_elem(parent, name));
}

bool parse_rss20(xmlDocPtr doc, FeedResult& result, std::string* err) {
    xmlNode* root = xmlDocGetRootElement(doc);
    if (!root) { set_err(err, "no root element"); return false; }
    xmlNode* channel = child_elem(root, "channel");
    if (!channel) { set_err(err, "no <channel> in RSS"); return false; }

    result.title       = child_text(channel, "title");
    result.description = child_text(channel, "description");
    result.link        = child_text(channel, "link");
    result.language    = child_text(channel, "language");

    for (xmlNode* cur = channel->children; cur; cur = cur->next) {
        if (cur->type != XML_ELEMENT_NODE) continue;
        if (!xmlStrEqual(cur->name, reinterpret_cast<const xmlChar*>("item"))) continue;

        FeedItem item;
        item.title       = child_text(cur, "title");
        item.description = child_text(cur, "description");
        item.link        = child_text(cur, "link");
        item.pub_date    = child_text(cur, "pubDate");
        item.guid        = child_text(cur, "guid");
        result.items.push_back(std::move(item));
    }
    return true;
}

bool parse_atom(xmlDocPtr doc, FeedResult& result, std::string* err) {
    xmlNode* root = xmlDocGetRootElement(doc);
    if (!root) { set_err(err, "no root element"); return false; }

    result.title = child_text(root, "title");
    result.description = child_text(root, "subtitle");

    for (xmlNode* cur = root->children; cur; cur = cur->next) {
        if (cur->type != XML_ELEMENT_NODE) continue;
        if (!xmlStrEqual(cur->name, reinterpret_cast<const xmlChar*>("link"))) continue;
        xmlChar* href = xmlGetProp(cur, reinterpret_cast<const xmlChar*>("href"));
        if (href) {
            result.link = reinterpret_cast<const char*>(href);
            xmlFree(href);
            break;
        }
    }

    result.language = child_text(root, "language");

    for (xmlNode* cur = root->children; cur; cur = cur->next) {
        if (cur->type != XML_ELEMENT_NODE) continue;
        if (!xmlStrEqual(cur->name, reinterpret_cast<const xmlChar*>("entry"))) continue;

        FeedItem item;
        item.title = child_text(cur, "title");

        item.description = child_text(cur, "summary");
        if (item.description.empty())
            item.description = child_text(cur, "content");

        for (xmlNode* link = cur->children; link; link = link->next) {
            if (link->type != XML_ELEMENT_NODE) continue;
            if (!xmlStrEqual(link->name, reinterpret_cast<const xmlChar*>("link"))) continue;
            xmlChar* href = xmlGetProp(link, reinterpret_cast<const xmlChar*>("href"));
            if (href) {
                item.link = reinterpret_cast<const char*>(href);
                xmlFree(href);
                break;
            }
        }

        item.pub_date = child_text(cur, "published");
        if (item.pub_date.empty())
            item.pub_date = child_text(cur, "updated");

        item.guid = child_text(cur, "id");
        result.items.push_back(std::move(item));
    }
    return true;
}

std::string trim(const std::string& s) {
    size_t start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

} // anonymous namespace

static bool tag_match(xmlNode* node, const char* name) {
    return node->type == XML_ELEMENT_NODE
           && xmlStrEqual(node->name, reinterpret_cast<const xmlChar*>(name));
}

static bool is_block_element(xmlNode* node) {
    if (node->type != XML_ELEMENT_NODE) return false;
    static const char* blocks[] = {
        "p", "br", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd", "table", "tr", "td", "th",
        "blockquote", "pre", "hr", "address", "center", "fieldset", "legend",
        nullptr
    };
    for (int i = 0; blocks[i]; i++) {
        if (tag_match(node, blocks[i])) return true;
    }
    return false;
}

static bool is_skippable(xmlNode* node) {
    return tag_match(node, "script") || tag_match(node, "style")
           || tag_match(node, "head");
}

// Recursively walk DOM extracting text; skip script/style/head; add newlines after blocks.
// "out" accumulates text from all children of "node".
static void extract_text(xmlNode* node, std::string& out) {
    for (xmlNode* cur = node; cur; cur = cur->next) {
        if (cur->type == XML_TEXT_NODE) {
            if (cur->content) {
                out += reinterpret_cast<const char*>(cur->content);
            }
        } else if (cur->type == XML_ELEMENT_NODE) {
            if (is_skippable(cur)) continue;
            if (cur->children) {
                extract_text(cur->children, out);
            }
            if (is_block_element(cur) && !out.empty() && out.back() != '\n') {
                out += '\n';
            }
        }
    }
}

// Find the <body> node in an HTML document.
static xmlNode* find_body(xmlDocPtr doc) {
    xmlNode* html = xmlDocGetRootElement(doc);
    if (!html) return nullptr;
    for (xmlNode* cur = html->children; cur; cur = cur->next) {
        if (tag_match(cur, "body")) return cur;
    }
    return html->children;  // fallback: process all children of <html>
}

std::string strip_html(const std::string& html) {
    if (html.empty()) return {};
    if (html.find('<') == std::string::npos || html.find('>') == std::string::npos) {
        return trim(html);
    }
    xmlDocPtr doc = htmlReadMemory(html.data(), static_cast<int>(html.size()),
                                    nullptr, nullptr,
                                    HTML_PARSE_RECOVER | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING);
    if (!doc) return trim(html);
    std::string result;
    xmlNode* body = find_body(doc);
    if (body && body->children) {
        extract_text(body->children, result);
    }
    xmlFreeDoc(doc);
    return trim(result);
}

std::optional<FeedResult> parse_feed(const std::string& xml, std::string* err) {
    xmlDocPtr doc = xmlParseMemory(xml.data(), static_cast<int>(xml.size()));
    if (!doc) {
        set_err(err, "XML parse error");
        return std::nullopt;
    }

    xmlNode* root = xmlDocGetRootElement(doc);
    if (!root) {
        set_err(err, "empty document");
        xmlFreeDoc(doc);
        return std::nullopt;
    }

    FeedResult result;
    bool ok = false;

    if (xmlStrEqual(root->name, reinterpret_cast<const xmlChar*>("rss"))) {
        ok = parse_rss20(doc, result, err);
    } else if (xmlStrEqual(root->name, reinterpret_cast<const xmlChar*>("feed"))) {
        ok = parse_atom(doc, result, err);
    } else {
        set_err(err, "unknown root element: expected <rss> or <feed>");
    }

    xmlFreeDoc(doc);
    if (!ok) return std::nullopt;
    return result;
}

void init_feed_parser() {
    xmlInitParser();
    LIBXML_TEST_VERSION
}

void cleanup_feed_parser() {
    xmlCleanupParser();
}

} // namespace jsonrpc
