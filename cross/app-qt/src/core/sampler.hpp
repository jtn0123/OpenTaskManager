// Reads the machine and its processes once per interval from Linux's /proc.
// Rates need two readings, so the first one after a pause only primes the
// counters: nothing is reported from it rather than a zero the system never
// measured. A figure the system didn't give is std::nullopt, never zero.
#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace otm {

// A process is its PID and start time, so a reused PID never inherits
// another process's figures or selection.
struct ProcessKey {
    int pid = 0;
    std::uint64_t startTicks = 0;  // Clock ticks after boot.
    bool operator==(const ProcessKey&) const = default;
};

struct ProcessKeyHash {
    std::size_t operator()(const ProcessKey& key) const noexcept {
        return std::hash<std::uint64_t>{}((static_cast<std::uint64_t>(key.pid) << 40) ^ key.startTicks);
    }
};

struct ProcessRow {
    ProcessKey key;
    std::string name;
    std::optional<std::string> user;     // None when the account can't be named.
    std::optional<double> cpu;           // Percent of one CPU; none on a first sighting.
    std::uint64_t memory = 0;            // Resident bytes.
    std::optional<double> diskRead;      // Bytes per second; none for another
    std::optional<double> diskWrite;     // account's process or a first sighting.
};

// Bytes per second each way: read and write, or received and sent.
struct Rates {
    double first = 0;
    double second = 0;
};

struct Snapshot {
    double interval = 0;                 // Seconds the interval covered.
    double cpu = 0;                      // Busy share of the whole CPU, 0–100.
    std::vector<double> cores;           // Each logical CPU, 0–100.
    std::uint64_t memoryUsed = 0;
    std::uint64_t memoryTotal = 0;
    std::uint64_t swapUsed = 0;
    std::uint64_t swapTotal = 0;
    std::optional<Rates> disk;           // None when no disk reports.
    std::optional<Rates> network;        // None when only loopback is listed.
};

struct Sample {
    Snapshot snapshot;
    std::optional<std::vector<ProcessRow>> processes;
};

class Sampler {
public:
    Sampler();

    // None from the very first call, which only primes the counters. The
    // process list is none on the first interval processes are read after a
    // pause, for the same reason.
    std::optional<Sample> sample(bool withProcesses);

    std::size_t logicalCpus() const { return previousCores_.size(); }

private:
    struct Ticks {
        std::uint64_t busy = 0;
        std::uint64_t total = 0;
    };
    struct Seen {
        std::uint64_t ticks = 0;
        std::optional<std::uint64_t> read;
        std::optional<std::uint64_t> written;
        std::string name;
    };
    using SeenMap = std::unordered_map<ProcessKey, Seen, ProcessKeyHash>;

    std::vector<ProcessRow> readProcesses(const SeenMap* previous, double interval, SeenMap& now);
    std::optional<std::string> userName(unsigned uid);

    std::optional<std::chrono::steady_clock::time_point> last_;
    Ticks previousTotal_;
    std::vector<Ticks> previousCores_;
    std::optional<Rates> previousDisk_;
    std::optional<Rates> previousNetwork_;
    std::optional<SeenMap> seen_;
    std::unordered_map<unsigned, std::optional<std::string>> users_;
    unsigned me_ = 0;
    bool superuser_ = false;
    double ticksPerSecond_ = 100;
    std::uint64_t pageSize_ = 4096;
};

// Linux keeps only a process name's first 15 bytes; when the command's own
// first word starts with that, its file name is the whole name.
std::string fullName(const std::string& name, const std::optional<std::string>& firstArgument);

}  // namespace otm
