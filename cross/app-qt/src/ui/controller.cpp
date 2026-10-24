#include "controller.hpp"

#include <QApplication>
#include <QIcon>
#include <QImage>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QSystemTrayIcon>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>

namespace {

constexpr int span = 60;
constexpr auto interval = std::chrono::seconds(1);

QString text(const std::string& value) { return QString::fromStdString(value); }

// Recent CPU load as two-pixel bars, newest on the right, in a dim frame.
QIcon cpuIcon(const std::deque<otm::Snapshot>& snapshots) {
    constexpr int size = 32;
    QImage image(size, size, QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    painter.setPen(QColor(0x80, 0x80, 0x80, 0xa0));
    painter.drawRect(0, 0, size - 1, size - 1);
    const int inner = size - 2;
    int slot = 0;
    for (auto at = snapshots.rbegin(); at != snapshots.rend() && slot < inner / 2; ++at, ++slot) {
        const int height = static_cast<int>(std::ceil(std::clamp(at->cpu, 0.0, 100.0) / 100.0 * inner));
        painter.fillRect(1 + inner - 2 * (slot + 1), 1 + inner - height, 2, height, QColor(0x35, 0xd0, 0x7f));
    }
    return QIcon(QPixmap::fromImage(image));
}

}  // namespace

Controller::Controller(bool startHidden) {
    if (QSystemTrayIcon::isSystemTrayAvailable()) {
        tray_ = new QSystemTrayIcon(this);
        auto* menu = new QMenu();
        menu->addAction("Open OpenTaskManager", this, &Controller::openWindow);
        menu->addAction("Quit OpenTaskManager", qApp, &QApplication::quit);
        connect(qApp, &QObject::destroyed, menu, &QObject::deleteLater);
        tray_->setContextMenu(menu);
        connect(tray_, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason reason) {
            if (reason == QSystemTrayIcon::Trigger) openWindow();
        });
        tray_->setIcon(cpuIcon(snapshots_));
        tray_->show();
    } else {
        std::fprintf(stderr, "No system tray here: closing the window leaves the app running without one.\n");
    }
    if (!startHidden) openWindow();

    sampler_ = std::thread([this] {
        otm::Sampler sampler;
        auto next = std::chrono::steady_clock::now();
        while (running_) {
            next += interval;
            const auto now = std::chrono::steady_clock::now();
            if (next <= now) next = now + interval;  // Asleep or stalled: start afresh, no burst.
            {
                std::unique_lock lock(wake_);
                if (stop_.wait_until(lock, next, [this] { return !running_; })) return;
            }
            auto sample = sampler.sample(showing_);
            if (!sample) continue;
            QMetaObject::invokeMethod(
                this, [this, taken = std::move(*sample)]() mutable { takeSample(std::move(taken)); }, Qt::QueuedConnection);
        }
    });
}

Controller::~Controller() {
    {
        std::lock_guard lock(wake_);
        running_ = false;
    }
    stop_.notify_all();
    if (sampler_.joinable()) sampler_.join();
    delete window_;
}

void Controller::openWindow() {
    if (window_) {
        window_->showNormal();
        window_->raise();
        window_->activateWindow();
        return;
    }
    auto* window = new MainWindow(span);
    window->setAttribute(Qt::WA_DeleteOnClose);
    window_ = window;
    connect(window, &MainWindow::searchChanged, this, [this](const QString& query) {
        query_ = query.toStdString();
        drawTable();
    });
    connect(window, &MainWindow::sortRequested, this, [this](int section) {
        const auto column = static_cast<otm::Column>(section);
        descending_ = column == sortColumn_ ? !descending_ : otm::numeric(column);
        sortColumn_ = column;
        drawTable();
    });
    connect(window, &MainWindow::rowSelected, this, [this](int row) {
        if (row >= 0 && static_cast<std::size_t>(row) < shown_.size()) selected_ = shown_[static_cast<std::size_t>(row)];
    });
    // Closing destroys the window; the tray keeps sampling.
    connect(window, &QObject::destroyed, this, [this] {
        showing_ = false;
        processes_.reset();
        shown_.clear();
    });
    window->markSort(static_cast<int>(sortColumn_), descending_);
    showing_ = true;
    drawGraphs();
    drawTable();
    window->show();
}

void Controller::takeSample(otm::Sample sample) {
    logicalCpus_ = std::max<std::size_t>(sample.snapshot.cores.size(), 1);
    snapshots_.push_back(std::move(sample.snapshot));
    while (snapshots_.size() > span) snapshots_.pop_front();
    ++samples_;
    double disk = 0;
    double network = 0;
    for (const otm::Snapshot& snapshot : snapshots_) {
        if (snapshot.disk) disk = std::max({disk, snapshot.disk->first, snapshot.disk->second});
        if (snapshot.network) network = std::max({network, snapshot.network->first, snapshot.network->second});
    }
    disk_.update(disk);
    network_.update(network);
    drawTray();

    const bool visible = window_ && window_->isVisible() && !window_->isMinimized();
    showing_ = visible;
    if (!visible) return;
    drawGraphs();
    if (sample.processes) {
        processes_ = std::move(sample.processes);
        drawTable();
    }
}

void Controller::drawTray() {
    if (tray_ != nullptr) tray_->setIcon(cpuIcon(snapshots_));
}

void Controller::drawGraphs() {
    if (!window_) return;
    const auto series = [this](auto pick) {
        std::vector<std::optional<double>> values;
        values.reserve(snapshots_.size());
        for (const otm::Snapshot& snapshot : snapshots_) values.push_back(pick(snapshot));
        return values;
    };
    const otm::Snapshot* latest = snapshots_.empty() ? nullptr : &snapshots_.back();

    window_->cpu->set(text(otm::percent(latest ? std::optional(latest->cpu) : std::nullopt)),
                      QString("%1 logical CPUs").arg(logicalCpus_),
                      {{series([](const otm::Snapshot& s) { return std::optional(s.cpu); }), false, true}}, 100, "100%",
                      samples_);

    const auto memoryShare = [](const otm::Snapshot& s) {
        return s.memoryTotal > 0 ? std::optional(100.0 * static_cast<double>(s.memoryUsed) / static_cast<double>(s.memoryTotal))
                                 : std::nullopt;
    };
    const QString memoryCaption =
        latest ? text(otm::bytes(static_cast<double>(latest->memoryUsed)) + " of " +
                      otm::bytes(static_cast<double>(latest->memoryTotal)) + " · swap " +
                      otm::bytes(static_cast<double>(latest->swapUsed)))
               : QString();
    window_->memory->set(text(otm::percent(latest ? memoryShare(*latest) : std::nullopt)), memoryCaption,
                         {{series(memoryShare), false, true}}, 100, "100%", samples_);

    const auto rates = [&](GraphCard* card, const std::optional<otm::Rates> otm::Snapshot::* field, double top,
                           const char* first, const char* second, const char* none) {
        const auto& now = latest ? latest->*field : std::optional<otm::Rates>();
        const QString value = now ? text(otm::rate(now->first + now->second)) : QString::fromUtf8(otm::missing);
        const QString caption = now ? QString("%1 %2 · %3 %4 (dashed)")
                                          .arg(QString::fromUtf8(first), text(otm::rate(now->first)), QString::fromUtf8(second),
                                               text(otm::rate(now->second)))
                                    : QString::fromUtf8(none);
        card->set(value, caption,
                  {{series([field](const otm::Snapshot& s) { return (s.*field) ? std::optional((s.*field)->first) : std::nullopt; }),
                    false, false},
                   {series([field](const otm::Snapshot& s) { return (s.*field) ? std::optional((s.*field)->second) : std::nullopt; }),
                    true, false}},
                  top, text(otm::axisRate(top)), samples_);
    };
    rates(window_->disk, &otm::Snapshot::disk, disk_.bound(), "Read", "write", "No disk reported its traffic");
    rates(window_->network, &otm::Snapshot::network, network_.bound(), "In", "out", "No network interface listed");
}

void Controller::drawTable() {
    if (!window_) return;
    if (!processes_) {
        window_->setStatus("Reading processes… · every 1 s");
        return;
    }
    const auto arranged = otm::arrange(*processes_, query_, sortColumn_, descending_, logicalCpus_);
    std::vector<ProcessModel::Cells> cells;
    shown_.clear();
    cells.reserve(arranged.size());
    for (const otm::ProcessRow* row : arranged) {
        const auto texts = otm::cells(*row, logicalCpus_);
        ProcessModel::Cells converted;
        for (std::size_t i = 0; i < texts.size(); ++i) converted[i] = text(texts[i]);
        cells.push_back(std::move(converted));
        shown_.push_back(row->key);
    }
    const auto keys = shown_;
    window_->model()->setRows(std::move(cells), keys);
    window_->markSort(static_cast<int>(sortColumn_), descending_);
    const int row = selected_ ? window_->model()->rowOf(*selected_) : -1;
    if (row < 0) selected_.reset();
    window_->selectRow(row);
    const QString count = shown_.size() == processes_->size()
                              ? QString("%1 processes").arg(processes_->size())
                              : QString("Showing %1 of %2 processes").arg(shown_.size()).arg(processes_->size());
    window_->setStatus(QString("%1 · every 1 s · CPU as a share of all %2 CPUs · “—” means the system didn't say")
                           .arg(count)
                           .arg(logicalCpus_));
}
