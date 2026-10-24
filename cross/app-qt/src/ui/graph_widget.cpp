#include "graph_widget.hpp"

#include <QPainter>
#include <QPainterPath>

#include <algorithm>
#include <cmath>
#include <utility>

namespace {
constexpr int rows = 4;
constexpr qint64 columnEvery = 10;
}  // namespace

GraphWidget::GraphWidget(QColor accent, int span, QWidget* parent)
    : QWidget(parent), accent_(accent), span_(std::max(span, 2)) {
    setFixedHeight(96);
    setAttribute(Qt::WA_OpaquePaintEvent);
}

void GraphWidget::plot(std::vector<GraphLine> lines, double top, QString topLabel, quint64 samples) {
    lines_ = std::move(lines);
    top_ = std::isfinite(top) && top > 0 ? top : 1;
    topLabel_ = std::move(topLabel);
    samples_ = samples;
    update();
}

void GraphWidget::paintEvent(QPaintEvent*) {
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    const double panelWidth = width();
    const double panelHeight = height();
    const double step = panelWidth / (span_ - 1);

    // The page shows around the panel's rounded corners.
    painter.fillRect(rect(), palette().window());
    QPainterPath panel;
    panel.addRoundedRect(QRectF(rect()), 5, 5);
    painter.setClipPath(panel);
    painter.fillRect(rect(), QColor(0x0b, 0x0f, 0x14));

    painter.setPen(QPen(QColor(255, 255, 255, 0x17), 1));
    for (int row = 1; row < rows; ++row) {
        const double y = std::round(panelHeight * row / rows) + 0.5;
        painter.drawLine(QPointF(0, y), QPointF(panelWidth, y));
    }
    for (int age = 0; age < span_; ++age) {
        const qint64 sample = static_cast<qint64>(samples_) - age;
        if (((sample % columnEvery) + columnEvery) % columnEvery != 0) continue;
        const double x = std::round(panelWidth - age * step) - 0.5;
        painter.drawLine(QPointF(x, 0), QPointF(x, panelHeight));
    }

    const auto yOf = [&](double value) { return panelHeight - 1 - std::clamp(value / top_, 0.0, 1.0) * (panelHeight - 2); };
    for (const GraphLine& line : lines_) {
        // Runs of readings, broken wherever one is missing.
        std::vector<std::vector<QPointF>> runs(1);
        const int count = std::min<int>(static_cast<int>(line.values.size()), span_);
        for (int index = static_cast<int>(line.values.size()) - count; index < static_cast<int>(line.values.size()); ++index) {
            const int age = static_cast<int>(line.values.size()) - 1 - index;
            const auto& value = line.values[static_cast<std::size_t>(index)];
            if (value && std::isfinite(*value)) {
                runs.back().emplace_back(panelWidth - age * step, yOf(*value));
            } else if (!runs.back().empty()) {
                runs.emplace_back();
            }
        }
        QPen pen(accent_, 1.75);
        pen.setJoinStyle(Qt::RoundJoin);
        if (line.dashed) pen.setDashPattern({3, 2});
        for (const auto& run : runs) {
            if (run.empty()) continue;
            if (run.size() == 1) {
                painter.setPen(pen);
                painter.drawLine(run[0], run[0] - QPointF(2, 0));
                continue;
            }
            QPainterPath path(run[0]);
            for (std::size_t i = 1; i < run.size(); ++i) path.lineTo(run[i]);
            if (line.fill) {
                QPainterPath area = path;
                area.lineTo(run.back().x(), panelHeight);
                area.lineTo(run.front().x(), panelHeight);
                area.closeSubpath();
                QColor fill = accent_;
                fill.setAlphaF(0.2f);
                painter.fillPath(area, fill);
            }
            painter.strokePath(path, pen);
        }
    }

    painter.setClipping(false);
    QFont font = painter.font();
    font.setPixelSize(11);
    painter.setFont(font);
    painter.setPen(QColor(255, 255, 255, 179));
    painter.drawText(QPointF(5, 14), topLabel_);
}
