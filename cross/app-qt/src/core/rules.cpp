#include "rules.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <variant>

namespace otm {
namespace {

constexpr std::array<const char*, 5> units{"B", "KB", "MB", "GB", "TB"};

struct InUnits {
    double scaled;
    const char* unit;
    bool isBytes;
};

InUnits inUnits(double value) {
    std::size_t index = 0;
    while (value >= 1024 && index < units.size() - 1) {
        value /= 1024;
        ++index;
    }
    return {value, units[index], index == 0};
}

bool usable(std::optional<double> value) { return value && std::isfinite(*value) && *value >= 0; }

std::string formatted(const char* pattern, double value, const char* unit) {
    std::array<char, 64> text{};
    std::snprintf(text.data(), text.size(), pattern, value, unit);
    return text.data();
}

std::string lower(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return std::tolower(c); });
    return text;
}

using Value = std::variant<std::monostate, double, std::string>;  // monostate: missing

Value value(const ProcessRow& row, Column column, std::size_t logicalCpus) {
    const auto number = [](std::optional<double> figure) { return figure ? Value(*figure) : Value(); };
    switch (column) {
        case Column::Name: return lower(row.name);
        case Column::Pid: return static_cast<double>(row.key.pid);
        case Column::User: return row.user ? Value(lower(*row.user)) : Value();
        case Column::Cpu: return number(machineShare(row, logicalCpus));
        case Column::Memory: return static_cast<double>(row.memory);
        case Column::DiskRead: return number(row.diskRead);
        case Column::DiskWrite: return number(row.diskWrite);
    }
    return Value();
}

}  // namespace

std::string bytes(std::optional<double> value) {
    if (!usable(value)) return missing;
    const auto [scaled, unit, isBytes] = inUnits(*value);
    const char* pattern = isBytes || scaled >= 100 ? "%.0f %s" : scaled >= 10 ? "%.1f %s" : "%.2f %s";
    return formatted(pattern, scaled, unit);
}

std::string rate(std::optional<double> value) { return usable(value) ? bytes(value) + "/s" : missing; }

std::string axisRate(double value) {
    if (!usable(value)) return missing;
    const auto [scaled, unit, isBytes] = inUnits(value);
    (void)isBytes;
    std::string text = formatted("%.2f", scaled, "");
    text.erase(text.find_last_not_of('0') + 1);
    if (!text.empty() && text.back() == '.') text.pop_back();
    return text + " " + unit + "/s";
}

std::string percent(std::optional<double> value) {
    if (!value || !std::isfinite(*value)) return missing;
    const double clamped = std::max(0.0, *value);
    return formatted(clamped < 10 ? "%.1f%s" : "%.0f%s", clamped, "%");
}

double roundStep(double value) {
    if (!std::isfinite(value) || value <= 0) return 0;
    const double power = std::pow(10.0, std::floor(std::log10(value)));
    for (const double factor : {1.0, 2.0, 5.0, 10.0}) {
        if (factor * power >= value * (1 - 1e-12)) return factor * power;
    }
    return 10 * power;
}

double roundBytes(double value) {
    if (!std::isfinite(value) || value <= 0) return 0;
    double unit = 1;
    while (value >= unit * 1024 * (1 - 1e-12)) unit *= 1024;
    const double step = roundStep(std::max(value / unit, 1.0));
    return step >= 1000 ? unit * 1024 : step * unit;  // 1000 of a unit reads better as 1 of the next.
}

AutoScale::AutoScale(double floor, int patience)
    : bound_(std::max(roundBytes(floor), 1.0)), floor_(bound_), patience_(patience) {}

double AutoScale::update(double visibleMax) {
    const double target = std::max(roundBytes(visibleMax), floor_);
    if (target > bound_) {
        bound_ = target;
        low_ = 0;
    } else if (target < bound_) {
        if (++low_ >= patience_) {
            bound_ = target;
            low_ = 0;
        }
    } else {
        low_ = 0;
    }
    return bound_;
}

const char* title(Column column) {
    static constexpr std::array<const char*, columnCount> titles{"Name",   "PID",       "User",      "CPU",
                                                                 "Memory", "Disk read", "Disk write"};
    return titles[static_cast<std::size_t>(column)];
}

bool numeric(Column column) { return column != Column::Name && column != Column::User; }

std::optional<double> machineShare(const ProcessRow& row, std::size_t logicalCpus) {
    if (!row.cpu) return std::nullopt;
    return *row.cpu / static_cast<double>(std::max<std::size_t>(logicalCpus, 1));
}

bool matches(const ProcessRow& row, const std::string& query) {
    const auto start = query.find_first_not_of(" \t");
    if (start == std::string::npos) return true;
    const std::string needle = lower(query.substr(start, query.find_last_not_of(" \t") - start + 1));
    return lower(row.name).find(needle) != std::string::npos || std::to_string(row.key.pid).starts_with(needle) ||
           (row.user && lower(*row.user).find(needle) != std::string::npos);
}

std::vector<const ProcessRow*> arrange(const std::vector<ProcessRow>& rows, const std::string& query, Column column,
                                       bool descending, std::size_t logicalCpus) {
    std::vector<std::pair<Value, const ProcessRow*>> kept;
    for (const ProcessRow& row : rows) {
        if (matches(row, query)) kept.emplace_back(value(row, column, logicalCpus), &row);
    }
    std::sort(kept.begin(), kept.end(), [descending](const auto& a, const auto& b) {
        const bool aMissing = std::holds_alternative<std::monostate>(a.first);
        const bool bMissing = std::holds_alternative<std::monostate>(b.first);
        if (aMissing != bMissing) return bMissing;  // Missing last, whichever the direction.
        if (!aMissing && a.first != b.first) return descending ? b.first < a.first : a.first < b.first;
        return a.second->key.pid < b.second->key.pid;
    });
    std::vector<const ProcessRow*> arranged;
    arranged.reserve(kept.size());
    for (const auto& entry : kept) arranged.push_back(entry.second);
    return arranged;
}

std::array<std::string, columnCount> cells(const ProcessRow& row, std::size_t logicalCpus) {
    return {row.name,
            std::to_string(row.key.pid),
            row.user.value_or(missing),
            percent(machineShare(row, logicalCpus)),
            bytes(static_cast<double>(row.memory)),
            rate(row.diskRead),
            rate(row.diskWrite)};
}

}  // namespace otm
