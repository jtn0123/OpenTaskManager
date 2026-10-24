// The window: four graph cards over the process table, the same slice as the
// Tauri and Slint apps. It's destroyed on close; the controller keeps the data.
#pragma once

#include <QFrame>
#include <QWidget>

#include "graph_widget.hpp"
#include "process_model.hpp"

class QLabel;
class QTableView;

class GraphCard : public QFrame {
    Q_OBJECT

public:
    GraphCard(const QString& title, QColor accent, int span, QWidget* parent = nullptr);
    void set(const QString& value, const QString& caption, std::vector<GraphLine> lines, double top,
             const QString& topLabel, quint64 samples);

private:
    QLabel* value_;
    QLabel* caption_;
    GraphWidget* graph_;
};

class MainWindow : public QWidget {
    Q_OBJECT

public:
    explicit MainWindow(int span, QWidget* parent = nullptr);

    GraphCard* cpu;
    GraphCard* memory;
    GraphCard* disk;
    GraphCard* network;

    ProcessModel* model() const { return model_; }
    void setStatus(const QString& text);
    void selectRow(int row);  // -1 clears the selection.
    void markSort(int column, bool descending);

signals:
    void searchChanged(const QString& text);
    void sortRequested(int column);
    void rowSelected(int row);

private:
    QTableView* table_;
    ProcessModel* model_;
    QLabel* status_;
};
