// Owns the sampling thread, the tray and the window's life. The window exists
// only while it's open; processes are read only while it's on screen.
#pragma once

#include <QObject>
#include <QPointer>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "main_window.hpp"
#include "rules.hpp"
#include "sampler.hpp"

class QSystemTrayIcon;

class Controller : public QObject {
    Q_OBJECT

public:
    explicit Controller(bool startHidden);
    ~Controller() override;

private:
    void openWindow();
    void takeSample(otm::Sample sample);
    void drawGraphs();
    void drawTable();
    void drawTray();

    QPointer<MainWindow> window_;
    QSystemTrayIcon* tray_ = nullptr;

    std::deque<otm::Snapshot> snapshots_;
    otm::AutoScale disk_{64.0 * 1024, 10};
    otm::AutoScale network_{16.0 * 1024, 10};
    quint64 samples_ = 0;
    std::size_t logicalCpus_ = 1;
    std::optional<std::vector<otm::ProcessRow>> processes_;
    otm::Column sortColumn_ = otm::Column::Cpu;
    bool descending_ = true;
    std::string query_;
    std::vector<otm::ProcessKey> shown_;
    std::optional<otm::ProcessKey> selected_;

    std::atomic<bool> showing_{false};
    std::atomic<bool> running_{true};
    std::mutex wake_;
    std::condition_variable stop_;
    std::thread sampler_;
};
