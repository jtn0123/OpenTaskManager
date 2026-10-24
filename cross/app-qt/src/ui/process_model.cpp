#include "process_model.hpp"

#include <algorithm>
#include <utility>

ProcessModel::ProcessModel(QObject* parent) : QAbstractTableModel(parent) {}

int ProcessModel::rowCount(const QModelIndex& parent) const {
    return parent.isValid() ? 0 : static_cast<int>(cells_.size());
}

int ProcessModel::columnCount(const QModelIndex& parent) const { return parent.isValid() ? 0 : otm::columnCount; }

QVariant ProcessModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() >= rowCount() || index.column() >= otm::columnCount) return {};
    if (role == Qt::DisplayRole) return cells_[static_cast<std::size_t>(index.row())][static_cast<std::size_t>(index.column())];
    if (role == Qt::TextAlignmentRole) {
        const bool figure = otm::numeric(static_cast<otm::Column>(index.column()));
        return QVariant::fromValue(Qt::AlignVCenter | (figure ? Qt::AlignRight : Qt::AlignLeft));
    }
    return {};
}

QVariant ProcessModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation != Qt::Horizontal || section < 0 || section >= otm::columnCount) return {};
    const auto column = static_cast<otm::Column>(section);
    if (role == Qt::DisplayRole) return QString::fromUtf8(otm::title(column));
    if (role == Qt::TextAlignmentRole) {
        return QVariant::fromValue(Qt::AlignVCenter | (otm::numeric(column) ? Qt::AlignRight : Qt::AlignLeft));
    }
    return {};
}

void ProcessModel::setRows(std::vector<Cells> cells, std::vector<otm::ProcessKey> keys) {
    const int before = rowCount();
    const int after = static_cast<int>(cells.size());
    if (after < before) {
        beginRemoveRows({}, after, before - 1);
        cells_.resize(static_cast<std::size_t>(after));
        keys_.resize(static_cast<std::size_t>(after));
        endRemoveRows();
    } else if (after > before) {
        beginInsertRows({}, before, after - 1);
        cells_.resize(static_cast<std::size_t>(after));
        keys_.resize(static_cast<std::size_t>(after));
        endInsertRows();
    }
    cells_ = std::move(cells);
    keys_ = std::move(keys);
    if (after > 0) emit dataChanged(index(0, 0), index(after - 1, otm::columnCount - 1), {Qt::DisplayRole});
}

std::optional<otm::ProcessKey> ProcessModel::keyAt(int row) const {
    if (row < 0 || row >= rowCount()) return std::nullopt;
    return keys_[static_cast<std::size_t>(row)];
}

int ProcessModel::rowOf(const otm::ProcessKey& key) const {
    const auto found = std::find(keys_.begin(), keys_.end(), key);
    return found == keys_.end() ? -1 : static_cast<int>(found - keys_.begin());
}
