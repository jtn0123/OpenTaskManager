// The display rules, the same as otm-core's: figures as text ("—" when
// missing, never zero), rate-axis tops, and the process table's search and order.
#pragma once

#include <array>
#include <optional>
#include <string>
#include <vector>

#include "sampler.hpp"

namespace otm {

inline constexpr const char* missing = "—";

std::string bytes(std::optional<double> value);
std::string rate(std::optional<double> value);
std::string axisRate(double value);  // Round values, no trailing zeros: "5 MB/s".
std::string percent(std::optional<double> value);

// The smallest round step (1, 2 or 5 times a power of ten) at or above `value`.
double roundStep(double value);
// The smallest round byte count at or above `value` in 1024-based units.
double roundBytes(double value);

// A rate graph's top: raised at once, lowered only after `patience` samples
// under a smaller step, never below `floor`.
class AutoScale {
public:
    AutoScale(double floor, int patience);
    double bound() const { return bound_; }
    double update(double visibleMax);

private:
    double bound_;
    double floor_;
    int patience_;
    int low_ = 0;
};

enum class Column { Name, Pid, User, Cpu, Memory, DiskRead, DiskWrite };
inline constexpr int columnCount = 7;
const char* title(Column column);
bool numeric(Column column);

std::optional<double> machineShare(const ProcessRow& row, std::size_t logicalCpus);
bool matches(const ProcessRow& row, const std::string& query);
// The rows a search keeps, sorted by `column`; missing figures last either way, ties by PID.
std::vector<const ProcessRow*> arrange(const std::vector<ProcessRow>& rows, const std::string& query, Column column,
                                       bool descending, std::size_t logicalCpus);
std::array<std::string, columnCount> cells(const ProcessRow& row, std::size_t logicalCpus);

}  // namespace otm
