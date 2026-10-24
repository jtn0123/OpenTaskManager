// The process table's rows, already filtered and sorted by the core's rules.
// Rows that stay are changed in place, so the view keeps its scroll position.
#pragma once

#include <QAbstractTableModel>
#include <QString>

#include <array>
#include <optional>
#include <vector>

#include "rules.hpp"

class ProcessModel : public QAbstractTableModel {
    Q_OBJECT

public:
    using Cells = std::array<QString, otm::columnCount>;

    explicit ProcessModel(QObject* parent = nullptr);

    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role) const override;

    void setRows(std::vector<Cells> cells, std::vector<otm::ProcessKey> keys);
    std::optional<otm::ProcessKey> keyAt(int row) const;
    int rowOf(const otm::ProcessKey& key) const;  // -1 when it isn't shown.

private:
    std::vector<Cells> cells_;
    std::vector<otm::ProcessKey> keys_;
};
