#include "sampler.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdlib>
#include <sstream>
#include <string_view>

namespace otm {
namespace {

// Reads a /proc or /sys file whole; empty when it can't be read (a process
// that ended, or a file this account may not read).
std::string readFile(const std::string& path) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return {};
    std::string text;
    std::array<char, 4096> buffer{};
    for (;;) {
        const ssize_t got = ::read(fd, buffer.data(), buffer.size());
        if (got <= 0) break;
        text.append(buffer.data(), static_cast<std::size_t>(got));
    }
    ::close(fd);
    return text;
}

std::uint64_t number(std::string_view text) {
    std::uint64_t value = 0;
    std::from_chars(text.data(), text.data() + text.size(), value);
    return value;
}

std::vector<std::string_view> words(std::string_view line) {
    std::vector<std::string_view> found;
    std::size_t at = 0;
    while (at < line.size()) {
        while (at < line.size() && (line[at] == ' ' || line[at] == '\t')) ++at;
        const std::size_t start = at;
        while (at < line.size() && line[at] != ' ' && line[at] != '\t') ++at;
        if (at > start) found.push_back(line.substr(start, at - start));
    }
    return found;
}

std::vector<std::string_view> lines(std::string_view text) {
    std::vector<std::string_view> found;
    std::size_t start = 0;
    while (start < text.size()) {
        std::size_t end = text.find('\n', start);
        if (end == std::string_view::npos) end = text.size();
        found.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    return found;
}

// "cpu" then "cpuN" lines of /proc/stat: busy and total ticks.
std::vector<std::pair<std::uint64_t, std::uint64_t>> cpuTicks() {
    std::vector<std::pair<std::uint64_t, std::uint64_t>> ticks;
    const std::string text = readFile("/proc/stat");
    for (const std::string_view line : lines(text)) {
        if (!line.starts_with("cpu")) break;
        const auto fields = words(line);
        if (fields.size() < 9) continue;
        // user nice system idle iowait irq softirq steal
        const std::uint64_t idle = number(fields[4]) + number(fields[5]);
        const std::uint64_t busy = number(fields[1]) + number(fields[2]) + number(fields[3]) + number(fields[6]) +
                                   number(fields[7]) + number(fields[8]);
        ticks.emplace_back(busy, busy + idle);
    }
    return ticks;
}

double share(std::uint64_t busy, std::uint64_t total) {
    return total == 0 ? 0.0 : std::clamp(100.0 * static_cast<double>(busy) / static_cast<double>(total), 0.0, 100.0);
}

// Whole physical disks (no partitions, loop or RAM disks), sectors read and written as bytes.
std::optional<Rates> diskBytes() {
    const std::string text = readFile("/proc/diskstats");
    Rates total;
    bool any = false;
    for (const std::string_view line : lines(text)) {
        const auto fields = words(line);
        if (fields.size() < 10) continue;
        const std::string name(fields[2]);
        if (name.starts_with("loop") || name.starts_with("ram") || name.starts_with("zram")) continue;
        struct stat info {};
        if (::stat(("/sys/block/" + name).c_str(), &info) != 0) continue;
        total.first += static_cast<double>(number(fields[5])) * 512.0;
        total.second += static_cast<double>(number(fields[9])) * 512.0;
        any = true;
    }
    return any ? std::optional<Rates>(total) : std::nullopt;
}

// Bytes received and sent over every interface except loopback.
std::optional<Rates> networkBytes() {
    const std::string text = readFile("/proc/net/dev");
    Rates total;
    bool any = false;
    for (const std::string_view line : lines(text)) {
        const std::size_t colon = line.find(':');
        if (colon == std::string_view::npos) continue;
        const auto name = words(line.substr(0, colon));
        if (name.empty() || name[0] == "lo") continue;
        const auto fields = words(line.substr(colon + 1));
        if (fields.size() < 9) continue;
        total.first += static_cast<double>(number(fields[0]));
        total.second += static_cast<double>(number(fields[8]));
        any = true;
    }
    return any ? std::optional<Rates>(total) : std::nullopt;
}

std::optional<Rates> perSecond(const std::optional<Rates>& now, const std::optional<Rates>& before, double interval) {
    if (!now || !before || interval <= 0) return std::nullopt;
    return Rates{std::max(0.0, now->first - before->first) / interval,
                 std::max(0.0, now->second - before->second) / interval};
}

std::uint64_t meminfo(std::string_view text, std::string_view key) {
    for (const std::string_view line : lines(text)) {
        if (line.starts_with(key) && line.size() > key.size() && line[key.size()] == ':') {
            const auto fields = words(line.substr(key.size() + 1));
            return fields.empty() ? 0 : number(fields[0]) * 1024;
        }
    }
    return 0;
}

std::optional<std::uint64_t> ioField(std::string_view text, std::string_view key) {
    for (const std::string_view line : lines(text)) {
        if (!line.starts_with(key)) continue;
        const auto fields = words(line.substr(key.size()));
        if (!fields.empty()) return number(fields[0]);
    }
    return std::nullopt;
}

}  // namespace

std::string fullName(const std::string& name, const std::optional<std::string>& firstArgument) {
    constexpr std::size_t linuxNameLimit = 15;
    if (name.size() >= linuxNameLimit && firstArgument) {
        const std::size_t slash = firstArgument->find_last_of("/\\");
        const std::string file = slash == std::string::npos ? *firstArgument : firstArgument->substr(slash + 1);
        if (file.size() > name.size() && file.starts_with(name)) return file;
    }
    return name;
}

Sampler::Sampler() {
    me_ = ::geteuid();
    superuser_ = me_ == 0;
    if (const long hz = ::sysconf(_SC_CLK_TCK); hz > 0) ticksPerSecond_ = static_cast<double>(hz);
    if (const long size = ::sysconf(_SC_PAGESIZE); size > 0) pageSize_ = static_cast<std::uint64_t>(size);
    const auto ticks = cpuTicks();
    if (!ticks.empty()) {
        previousTotal_ = {ticks[0].first, ticks[0].second};
        for (std::size_t i = 1; i < ticks.size(); ++i) previousCores_.push_back({ticks[i].first, ticks[i].second});
    }
}

std::optional<std::string> Sampler::userName(unsigned uid) {
    if (const auto known = users_.find(uid); known != users_.end()) return known->second;
    std::optional<std::string> name;
    passwd entry{};
    passwd* result = nullptr;
    std::array<char, 4096> buffer{};
    if (::getpwuid_r(uid, &entry, buffer.data(), buffer.size(), &result) == 0 && result != nullptr) {
        name = std::string(entry.pw_name);
    }
    users_.emplace(uid, name);
    return name;
}

std::vector<ProcessRow> Sampler::readProcesses(const SeenMap* previous, double interval, SeenMap& now) {
    std::vector<ProcessRow> rows;
    DIR* proc = ::opendir("/proc");
    if (proc == nullptr) return rows;
    while (const dirent* entry = ::readdir(proc)) {
        const std::string_view id(entry->d_name);
        if (id.empty() || !std::all_of(id.begin(), id.end(), [](char c) { return c >= '0' && c <= '9'; })) continue;
        const std::string base = "/proc/" + std::string(id);
        const std::string line = readFile(base + "/stat");
        const std::size_t open = line.find('(');
        const std::size_t close = line.rfind(')');
        if (open == std::string::npos || close == std::string::npos || close + 2 >= line.size()) continue;
        const auto fields = words(std::string_view(line).substr(close + 2));
        if (fields.size() < 22) continue;  // state ... utime(11) stime(12) ... starttime(19) ... rss(21)
        struct stat owner {};
        const bool ownerKnown = ::stat(base.c_str(), &owner) == 0;

        ProcessRow row;
        row.key = {static_cast<int>(number(id)), number(fields[19])};
        const std::uint64_t ticks = number(fields[11]) + number(fields[12]);
        row.memory = number(fields[21]) * pageSize_;
        if (ownerKnown) row.user = userName(owner.st_uid);

        const Seen* before = nullptr;
        if (previous != nullptr) {
            if (const auto found = previous->find(row.key); found != previous->end()) before = &found->second;
        }
        Seen seen;
        seen.ticks = ticks;
        const std::string comm = line.substr(open + 1, close - open - 1);
        if (before != nullptr) {
            seen.name = before->name;
        } else {
            std::optional<std::string> first;
            if (comm.size() >= 15) {
                const std::string command = readFile(base + "/cmdline");
                if (!command.empty()) first = std::string(command.c_str());
            }
            seen.name = fullName(comm, first);
        }
        row.name = seen.name;

        // Other accounts' I/O counters are private.
        if (superuser_ || (ownerKnown && owner.st_uid == me_)) {
            const std::string io = readFile(base + "/io");
            seen.read = ioField(io, "read_bytes:");
            seen.written = ioField(io, "write_bytes:");
        }
        if (before != nullptr && interval > 0) {
            row.cpu = static_cast<double>(ticks - std::min(ticks, before->ticks)) / ticksPerSecond_ / interval * 100.0;
            if (seen.read && before->read) row.diskRead = static_cast<double>(*seen.read - std::min(*seen.read, *before->read)) / interval;
            if (seen.written && before->written) {
                row.diskWrite = static_cast<double>(*seen.written - std::min(*seen.written, *before->written)) / interval;
            }
        }
        now.emplace(row.key, std::move(seen));
        rows.push_back(std::move(row));
    }
    ::closedir(proc);
    return rows;
}

std::optional<Sample> Sampler::sample(bool withProcesses) {
    const auto now = std::chrono::steady_clock::now();
    const auto previous = last_;
    last_ = now;
    const std::optional<double> interval =
        previous ? std::optional<double>(std::chrono::duration<double>(now - *previous).count()) : std::nullopt;

    Sample sample;
    Snapshot& snapshot = sample.snapshot;
    snapshot.interval = interval.value_or(0);
    const auto ticks = cpuTicks();
    if (!ticks.empty()) {
        snapshot.cpu = share(ticks[0].first - previousTotal_.busy, ticks[0].second - previousTotal_.total);
        previousTotal_ = {ticks[0].first, ticks[0].second};
        previousCores_.resize(ticks.size() - 1);
        for (std::size_t i = 1; i < ticks.size(); ++i) {
            Ticks& before = previousCores_[i - 1];
            snapshot.cores.push_back(share(ticks[i].first - before.busy, ticks[i].second - before.total));
            before = {ticks[i].first, ticks[i].second};
        }
    }
    const std::string memory = readFile("/proc/meminfo");
    snapshot.memoryTotal = meminfo(memory, "MemTotal");
    snapshot.memoryUsed = snapshot.memoryTotal - std::min(snapshot.memoryTotal, meminfo(memory, "MemAvailable"));
    snapshot.swapTotal = meminfo(memory, "SwapTotal");
    snapshot.swapUsed = snapshot.swapTotal - std::min(snapshot.swapTotal, meminfo(memory, "SwapFree"));
    const auto disk = diskBytes();
    const auto network = networkBytes();
    if (interval) {
        snapshot.disk = perSecond(disk, previousDisk_, *interval);
        snapshot.network = perSecond(network, previousNetwork_, *interval);
    }
    previousDisk_ = disk;
    previousNetwork_ = network;

    if (withProcesses) {
        SeenMap seenNow;
        auto rows = readProcesses(seen_ ? &*seen_ : nullptr, interval.value_or(0), seenNow);
        if (seen_ && interval) sample.processes = std::move(rows);
        seen_ = std::move(seenNow);
    } else {
        seen_.reset();
    }
    if (!interval) return std::nullopt;
    return sample;
}

}  // namespace otm
