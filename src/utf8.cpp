#include "utf8.h"

std::string sanitize_utf8(const std::string& s) {
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
