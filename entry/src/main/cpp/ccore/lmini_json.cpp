#include "lmini_json.h"

#include <cctype>
#include <cstdlib>

namespace lcore {

namespace {

struct Cursor {
    const std::string& s;
    size_t i;
    explicit Cursor(const std::string& str) : s(str), i(0) {}
};

// RFC 8259 allows implementations to cap nesting depth. Without a cap a
// malicious document (e.g. thousands of nested arrays from a remote
// subscription) exhausts the stack and crashes the process.
constexpr int kMaxDepth = 64;

bool SkipWs(Cursor& c) {
    while (c.i < c.s.size() && (c.s[c.i] == ' ' || c.s[c.i] == '\t' || c.s[c.i] == '\n' || c.s[c.i] == '\r')) {
        ++c.i;
    }
    return c.i < c.s.size();
}

bool ParseValue(Cursor& c, Json& out, std::string& err, int depth);

void AppendUtf8(std::string& out, unsigned int cp) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

int HexVal(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

bool ParseString(Cursor& c, Json& out, std::string& err) {
    ++c.i;  // opening quote
    std::string val;
    while (c.i < c.s.size()) {
        char ch = c.s[c.i];
        if (ch == '"') {
            ++c.i;
            out.type = Json::Type::String;
            out.str = std::move(val);
            return true;
        }
        if (ch == '\\') {
            if (c.i + 1 >= c.s.size()) {
                err = "unterminated escape";
                return false;
            }
            char e = c.s[c.i + 1];
            switch (e) {
                case '"': val.push_back('"'); break;
                case '\\': val.push_back('\\'); break;
                case '/': val.push_back('/'); break;
                case 'b': val.push_back('\b'); break;
                case 'f': val.push_back('\f'); break;
                case 'n': val.push_back('\n'); break;
                case 'r': val.push_back('\r'); break;
                case 't': val.push_back('\t'); break;
                case 'u': {
                    if (c.i + 5 >= c.s.size()) {
                        err = "truncated \\u escape";
                        return false;
                    }
                    unsigned int cp = 0;
                    for (int k = 0; k < 4; ++k) {
                        int hv = HexVal(c.s[c.i + 2 + k]);
                        if (hv < 0) {
                            err = "bad \\u escape";
                            return false;
                        }
                        cp = (cp << 4) | static_cast<unsigned int>(hv);
                    }
                    // Combine UTF-16 surrogate pairs; lone surrogates are
                    // invalid JSON and must not be emitted as bad UTF-8.
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        if (c.i + 11 >= c.s.size() || c.s[c.i + 6] != '\\' || c.s[c.i + 7] != 'u') {
                            err = "truncated surrogate pair";
                            return false;
                        }
                        unsigned int lo = 0;
                        for (int k = 0; k < 4; ++k) {
                            int hv = HexVal(c.s[c.i + 8 + k]);
                            if (hv < 0) {
                                err = "bad surrogate pair";
                                return false;
                            }
                            lo = (lo << 4) | static_cast<unsigned int>(hv);
                        }
                        if (lo < 0xDC00 || lo > 0xDFFF) {
                            err = "invalid low surrogate";
                            return false;
                        }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        AppendUtf8(val, cp);
                        c.i += 10;  // consume both \uXXXX escapes
                        break;
                    }
                    if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        err = "unexpected low surrogate";
                        return false;
                    }
                    AppendUtf8(val, cp);
                    c.i += 4;
                    break;
                }
                default:
                    err = "unknown escape";
                    return false;
            }
            c.i += 2;
            continue;
        }
        val.push_back(ch);
        ++c.i;
    }
    err = "unterminated string";
    return false;
}

bool ParseNumber(Cursor& c, Json& out, std::string& err) {
    size_t start = c.i;
    if (c.i < c.s.size() && c.s[c.i] == '-') ++c.i;
    // integer part: "0" or [1-9] digits
    if (c.i >= c.s.size() || !isdigit(static_cast<unsigned char>(c.s[c.i]))) {
        err = "invalid number";
        return false;
    }
    if (c.s[c.i] == '0') {
        ++c.i;
    } else {
        while (c.i < c.s.size() && isdigit(static_cast<unsigned char>(c.s[c.i]))) ++c.i;
    }
    // fraction: '.' 1*DIGIT
    if (c.i < c.s.size() && c.s[c.i] == '.') {
        ++c.i;
        size_t fracStart = c.i;
        while (c.i < c.s.size() && isdigit(static_cast<unsigned char>(c.s[c.i]))) ++c.i;
        if (c.i == fracStart) {
            err = "invalid number fraction";
            return false;
        }
    }
    // exponent: [eE] [+-]? 1*DIGIT
    if (c.i < c.s.size() && (c.s[c.i] == 'e' || c.s[c.i] == 'E')) {
        ++c.i;
        if (c.i < c.s.size() && (c.s[c.i] == '+' || c.s[c.i] == '-')) ++c.i;
        size_t expStart = c.i;
        while (c.i < c.s.size() && isdigit(static_cast<unsigned char>(c.s[c.i]))) ++c.i;
        if (c.i == expStart) {
            err = "invalid number exponent";
            return false;
        }
    }
    out.type = Json::Type::Number;
    out.num = strtod(c.s.c_str() + start, nullptr);
    (void)start;
    return true;
}

bool ParseObject(Cursor& c, Json& out, std::string& err, int depth) {
    if (depth > kMaxDepth) {
        err = "nesting too deep";
        return false;
    }
    ++c.i;  // '{'
    out.type = Json::Type::Object;
    for (;;) {
        if (!SkipWs(c)) {
            err = "truncated object";
            return false;
        }
        if (c.s[c.i] == '}') {
            ++c.i;
            return true;
        }
        if (c.s[c.i] != '"') {
            err = "expected object key string";
            return false;
        }
        Json key;
        if (!ParseString(c, key, err)) return false;
        if (!SkipWs(c) || c.s[c.i] != ':') {
            err = "expected ':' after object key";
            return false;
        }
        ++c.i;
        Json val;
        if (!ParseValue(c, val, err, depth)) return false;
        out.obj.emplace_back(std::move(key.str), std::move(val));
        if (!SkipWs(c)) {
            err = "truncated object";
            return false;
        }
        if (c.s[c.i] == ',') {
            ++c.i;
            continue;
        }
        if (c.s[c.i] == '}') {
            ++c.i;
            return true;
        }
        err = "expected ',' or '}'";
        return false;
    }
}

bool ParseArray(Cursor& c, Json& out, std::string& err, int depth) {
    if (depth > kMaxDepth) {
        err = "nesting too deep";
        return false;
    }
    ++c.i;  // '['
    out.type = Json::Type::Array;
    for (;;) {
        if (!SkipWs(c)) {
            err = "truncated array";
            return false;
        }
        if (c.s[c.i] == ']') {
            ++c.i;
            return true;
        }
        Json val;
        if (!ParseValue(c, val, err, depth)) return false;
        out.arr.push_back(std::move(val));
        if (!SkipWs(c)) {
            err = "truncated array";
            return false;
        }
        if (c.s[c.i] == ',') {
            ++c.i;
            continue;
        }
        if (c.s[c.i] == ']') {
            ++c.i;
            return true;
        }
        err = "expected ',' or ']'";
        return false;
    }
}

bool ParseValue(Cursor& c, Json& out, std::string& err, int depth) {
    if (!SkipWs(c)) {
        err = "unexpected end of input";
        return false;
    }
    char ch = c.s[c.i];
    switch (ch) {
        case '{': return ParseObject(c, out, err, depth + 1);
        case '[': return ParseArray(c, out, err, depth + 1);
        case '"': return ParseString(c, out, err);
        case 't':
            if (c.s.compare(c.i, 4, "true") == 0) {
                out.type = Json::Type::Bool;
                out.b = true;
                c.i += 4;
                return true;
            }
            err = "invalid literal";
            return false;
        case 'f':
            if (c.s.compare(c.i, 5, "false") == 0) {
                out.type = Json::Type::Bool;
                out.b = false;
                c.i += 5;
                return true;
            }
            err = "invalid literal";
            return false;
        case 'n':
            if (c.s.compare(c.i, 4, "null") == 0) {
                out.type = Json::Type::Null;
                c.i += 4;
                return true;
            }
            err = "invalid literal";
            return false;
        case '-':
        case '0':
        case '1':
        case '2':
        case '3':
        case '4':
        case '5':
        case '6':
        case '7':
        case '8':
        case '9':
            return ParseNumber(c, out, err);
        default:
            err = "unexpected character in JSON";
            return false;
    }
}

}  // namespace

bool Json::Parse(const std::string& text, Json& out, std::string& err) {
    Cursor c(text);
    if (!ParseValue(c, out, err, 1)) {
        return false;
    }
    SkipWs(c);
    if (c.i != text.size()) {
        err = "trailing content after JSON value";
        return false;
    }
    return true;
}

}  // namespace lcore