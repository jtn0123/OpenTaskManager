#include "main_window.hpp"

#include <QHBoxLayout>
#include <QHeaderView>
#include <QItemSelectionModel>
#include <QLabel>
#include <QLineEdit>
#include <QTableView>
#include <QVBoxLayout>

#include <utility>

namespace {

QLabel* mutedLabel(QWidget* parent) {
    auto* label = new QLabel(parent);
    QPalette palette = label->palette();
    QColor muted = palette.color(QPalette::WindowText);
    muted.setAlphaF(0.65f);
    palette.setColor(QPalette::WindowText, muted);
    label->setPalette(palette);
    QFont font = label->font();
    font.setPixelSize(12);
    label->setFont(font);
    return label;
}

}  // namespace

GraphCard::GraphCard(const QString& title, QColor accent, int span, QWidget* parent) : QFrame(parent) {
    setObjectName("card");
    setStyleSheet("QFrame#card { border: 1px solid palette(mid); border-radius: 8px; background: palette(base); }");
    setMinimumWidth(170);
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(8, 8, 8, 8);
    layout->setSpacing(6);

    auto* head = new QHBoxLayout;
    auto* name = new QLabel(title, this);
    name->setStyleSheet(QString("color: %1; font-weight: 600; font-size: 13px;").arg(accent.name()));
    value_ = new QLabel(this);
    value_->setStyleSheet("font-weight: 600; font-size: 15px;");
    value_->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    head->addWidget(name);
    head->addWidget(value_, 1);
    layout->addLayout(head);

    graph_ = new GraphWidget(accent, span, this);
    layout->addWidget(graph_);
    caption_ = mutedLabel(this);
    caption_->setMinimumWidth(1);  // Long captions are cut, not allowed to widen the card.
    layout->addWidget(caption_);
}

void GraphCard::set(const QString& value, const QString& caption, std::vector<GraphLine> lines, double top,
                    const QString& topLabel, quint64 samples) {
    if (value_->text() != value) value_->setText(value);
    const QString shown = caption_->fontMetrics().elidedText(caption, Qt::ElideRight, caption_->width());
    if (caption_->text() != shown) caption_->setText(shown);
    graph_->plot(std::move(lines), top, topLabel, samples);
}

MainWindow::MainWindow(int span, QWidget* parent) : QWidget(parent) {
    setWindowTitle("OpenTaskManager (Qt)");
    resize(1120, 760);
    setMinimumSize(760, 520);
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(10, 10, 10, 6);
    layout->setSpacing(10);

    auto* top = new QHBoxLayout;
    auto* title = new QLabel("OpenTaskManager", this);
    title->setStyleSheet("font-weight: 600; font-size: 15px;");
    auto* search = new QLineEdit(this);
    search->setPlaceholderText("Search by name, PID or user");
    search->setClearButtonEnabled(true);
    search->setFixedWidth(320);
    connect(search, &QLineEdit::textChanged, this, &MainWindow::searchChanged);
    top->addWidget(title);
    top->addStretch(1);
    top->addWidget(search);
    layout->addLayout(top);

    auto* cards = new QHBoxLayout;
    cards->setSpacing(10);
    cpu = new GraphCard("CPU", QColor(0x35, 0xd0, 0x7f), span, this);
    memory = new GraphCard("Memory", QColor(0xb3, 0x8c, 0xff), span, this);
    disk = new GraphCard("Disk", QColor(0xff, 0xb5, 0x47), span, this);
    network = new GraphCard("Network", QColor(0x4f, 0xb8, 0xff), span, this);
    for (GraphCard* card : {cpu, memory, disk, network}) cards->addWidget(card, 1);
    layout->addLayout(cards);

    model_ = new ProcessModel(this);
    table_ = new QTableView(this);
    table_->setModel(model_);
    table_->setSelectionBehavior(QAbstractItemView::SelectRows);
    table_->setSelectionMode(QAbstractItemView::SingleSelection);
    table_->setAlternatingRowColors(true);
    table_->setShowGrid(false);
    table_->setWordWrap(false);
    table_->verticalHeader()->hide();
    table_->verticalHeader()->setDefaultSectionSize(24);
    QHeaderView* header = table_->horizontalHeader();
    header->setSectionsClickable(true);
    header->setSortIndicatorShown(true);
    header->setSectionResizeMode(0, QHeaderView::Stretch);
    const int widths[] = {0, 80, 120, 72, 96, 104, 104};
    for (int column = 1; column < otm::columnCount; ++column) {
        header->setSectionResizeMode(column, QHeaderView::Fixed);
        header->resizeSection(column, widths[column]);
    }
    connect(header, &QHeaderView::sectionClicked, this, &MainWindow::sortRequested);
    connect(table_->selectionModel(), &QItemSelectionModel::currentRowChanged, this,
            [this](const QModelIndex& current) { emit rowSelected(current.isValid() ? current.row() : -1); });
    layout->addWidget(table_, 1);

    status_ = mutedLabel(this);
    layout->addWidget(status_);
}

void MainWindow::setStatus(const QString& text) {
    if (status_->text() != text) status_->setText(text);
}

void MainWindow::selectRow(int row) {
    QItemSelectionModel* selection = table_->selectionModel();
    if (row < 0) {
        selection->clear();
        return;
    }
    const QModelIndex index = model_->index(row, 0);
    if (selection->currentIndex().row() == row && selection->isRowSelected(row)) return;
    selection->setCurrentIndex(index, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
}

void MainWindow::markSort(int column, bool descending) {
    table_->horizontalHeader()->setSortIndicator(column, descending ? Qt::DescendingOrder : Qt::AscendingOrder);
}
