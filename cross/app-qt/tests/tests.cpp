// The C++ core's rules, checked the way otm-core checks its own.
#include <QTest>

#include <unistd.h>

#include <algorithm>
#include <thread>

#include "rules.hpp"
#include "sampler.hpp"

using otm::Column;
using otm::ProcessRow;

namespace {

ProcessRow row(int pid, const char* name, std::optional<double> cpu, std::optional<double> read) {
    ProcessRow made;
    made.key = {pid, 1};
    made.name = name;
    if (pid % 2 == 0) made.user = "justin";
    made.cpu = cpu;
    made.memory = static_cast<std::uint64_t>(pid) * 1024;
    made.diskRead = read;
    return made;
}

std::vector<int> pids(const std::vector<const ProcessRow*>& rows) {
    std::vector<int> found;
    for (const ProcessRow* each : rows) found.push_back(each->key.pid);
    return found;
}

}  // namespace

class CoreTests : public QObject {
    Q_OBJECT

private slots:
    void missingFiguresAreADashNeverZero() {
        QCOMPARE(otm::bytes(std::nullopt), std::string("—"));
        QCOMPARE(otm::rate(-1.0), std::string("—"));
        QCOMPARE(otm::percent(std::nullopt), std::string("—"));
    }

    void formatsLikeTheRustCore() {
        QCOMPARE(otm::bytes(512.0), std::string("512 B"));
        QCOMPARE(otm::bytes(1536.0), std::string("1.50 KB"));
        QCOMPARE(otm::bytes(190.0 * 1024 * 1024), std::string("190 MB"));
        QCOMPARE(otm::axisRate(5.0 * 1024 * 1024), std::string("5 MB/s"));
        QCOMPARE(otm::axisRate(1.5 * 1024 * 1024), std::string("1.5 MB/s"));
        QCOMPARE(otm::percent(9.94), std::string("9.9%"));
        QCOMPARE(otm::percent(12.6), std::string("13%"));
    }

    void roundsAxesInTheUnitsShown() {
        QCOMPARE(otm::roundBytes(700), 1024.0);
        QCOMPARE(otm::roundBytes(300 * 1024.0), 500 * 1024.0);
        QCOMPARE(otm::roundBytes(5'000'000), 5 * 1024.0 * 1024);
        otm::AutoScale scale(1024, 3);
        QCOMPARE(scale.update(150 * 1024.0), 200 * 1024.0);
        scale.update(9 * 1024.0);
        scale.update(9 * 1024.0);
        QCOMPARE(scale.update(9 * 1024.0), 10 * 1024.0);
    }

    void missingFiguresSortLastEitherWay() {
        const std::vector<ProcessRow> rows{row(1, "a", std::nullopt, std::nullopt), row(2, "b", 50.0, 1.0),
                                           row(3, "c", 10.0, 9.0)};
        QCOMPARE(pids(otm::arrange(rows, "", Column::Cpu, true, 1)), (std::vector<int>{2, 3, 1}));
        QCOMPARE(pids(otm::arrange(rows, "", Column::Cpu, false, 1)), (std::vector<int>{3, 2, 1}));
        QCOMPARE(pids(otm::arrange(rows, "", Column::DiskRead, true, 1)), (std::vector<int>{3, 2, 1}));
    }

    void searchesNameUserAndPidPrefix() {
        const ProcessRow firefox = row(4120, "Firefox", std::nullopt, std::nullopt);
        QVERIFY(otm::matches(firefox, "fire"));
        QVERIFY(otm::matches(firefox, "412"));
        QVERIFY(!otm::matches(firefox, "120"));
        QVERIFY(otm::matches(firefox, "JUSTIN"));
    }

    void recoversNamesLinuxCutShort() {
        QCOMPARE(otm::fullName("WebKitWebProces", std::string("/usr/lib/WebKitWebProcess")), std::string("WebKitWebProcess"));
        QCOMPARE(otm::fullName("short", std::string("/usr/bin/shorter")), std::string("short"));
        QCOMPARE(otm::fullName("abcdefghijklmno", std::string("/bin/other")), std::string("abcdefghijklmno"));
    }

    // Live: reads this machine, so it checks shapes and priming, not values.
    void primesBeforeReportingAndMeasuresProcessesOnTheirSecondReading() {
        otm::Sampler sampler;
        QVERIFY(!sampler.sample(true));
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        auto sample = sampler.sample(false);
        QVERIFY(sample);
        QVERIFY(!sample->processes);
        QVERIFY(sample->snapshot.memoryTotal > 0);
        QCOMPARE(sample->snapshot.cores.size(), sampler.logicalCpus());
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        QVERIFY(!sampler.sample(true)->processes);  // Primes again after a pause.
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        sample = sampler.sample(true);
        QVERIFY(sample && sample->processes);
        const int me = static_cast<int>(::getpid());
        const auto own = std::find_if(sample->processes->begin(), sample->processes->end(),
                                      [me](const ProcessRow& each) { return each.key.pid == me; });
        QVERIFY(own != sample->processes->end());
        QVERIFY(own->cpu.has_value());
        QVERIFY(own->diskRead.has_value());
        QVERIFY(own->memory > 0);
    }
};

QTEST_GUILESS_MAIN(CoreTests)
#include "tests.moc"
