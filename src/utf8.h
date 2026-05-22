#pragma once
#include <string>

// Replace invalid UTF-8 sequences with U+FFFD.
// Rejects overlong sequences, surrogate halves (U+D800-U+DFFF),
// and codepoints > U+10FFFF.
std::string sanitize_utf8(const std::string& s);
