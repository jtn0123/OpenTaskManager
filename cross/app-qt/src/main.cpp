// OpenTaskManager in C++ and Qt Widgets: the Tauri and Slint apps' slice
// (graphs, process table, tray) over a plain C++ /proc sampler.
#include <QApplication>

#include "controller.hpp"

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QApplication::setApplicationName("OpenTaskManager");
    // The last window closing isn't quitting: the tray stays. Quit comes from its menu.
    QApplication::setQuitOnLastWindowClosed(false);
    const bool startHidden = QApplication::arguments().contains("--hidden");
    Controller controller(startHidden);
    return QApplication::exec();
}
