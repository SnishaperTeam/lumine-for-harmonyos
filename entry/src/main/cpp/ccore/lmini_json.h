// Minimal recursive-descent JSON parser (config files, stats heartbeat).
// Portable C++17, no deps. Objects are kept as an ordered key/value array.
#ifndef LCORE_LMINI_JSON_H
#define LCORE_LMINI_JSON_H

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace lcore {

class Json {
  public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<Json> arr;
    std::vector<std::pair<std::string, Json>> obj;

    static bool Parse(const std::string& text, Json& out, std::string& err);

    bool IsNull() const { return type == Type::Null; }
    bool IsObject() const { return type == Type::Object; }
    bool IsString() const { return type == Type::String; }

    const Json* find(const std::string& key) const {
        if (type != Type::Object) return nullptr;
        for (const auto& kv : obj) {
            if (kv.first == key) return &kv.second;
        }
        return nullptr;
    }

    std::string getString(const std::string& key, const std::string& def) const {
        const Json* v = find(key);
        return (v && v->IsString()) ? v->str : def;
    }
    bool getBool(const std::string& key, bool def) const {
        const Json* v = find(key);
        return (v && v->type == Type::Bool) ? v->b : def;
    }
    double getNumber(const std::string& key, double def) const {
        const Json* v = find(key);
        return (v && v->type == Type::Number) ? v->num : def;
    }
};

}  // namespace lcore

#endif  // LCORE_LMINI_JSON_H