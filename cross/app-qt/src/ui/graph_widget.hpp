// A live graph painted once per sample with QPainter: a dark panel, rows and
// columns that move with the data, and lines broken wherever a reading is
// missing (never drawn as zero).
#pragma once

#include <QColor>
#include <QString>
#include <QWidget>

#include <optional>
#include <vector>

struct GraphLine {
    std::vector<std::optional<double>> values;  // Oldest first.
    bool dashed = false;                        // A second line never differs by colour alone.
    bool fill = false;
};

class GraphWidget : public QWidget {
    Q_OBJECT

public:
    GraphWidget(QColor accent, int span, QWidget* parent = nullptr);
    void plot(std::vector<GraphLine> lines, double top, QString topLabel, quint64 samples);

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    QColor accent_;
    int span_;
    std::vector<GraphLine> lines_;
    double top_ = 1;
    QString topLabel_;
    quint64 samples_ = 0;
};
