import Foundation
import OTMKit
import UserNotifications

extension ConnectionStore {
    func applyListeners(_ reading: ConnectionHistoryWorker.ListenerReading, acceptance: Int) {
        // A walk finishing before Accept must not put its earlier review back after acceptance has returned.
        #if DEBUG
        if showsListenerFixture {
            if listenerReview == nil { listenerReview = ListenerFixture.review() }
            return
        }
        #endif
        if acceptance == listenerAcceptance {
            if let review = reading.review, listenerReview != review { listenerReview = review }
            if listenerUnreadable != reading.unreadable { listenerUnreadable = reading.unreadable }
            if listenerError != reading.error { listenerError = reading.error }
        }
        notifyListenerChanges(reading.newChanges)
    }

    private func notifyListenerChanges(_ count: Int) {
        // Only background walks notify: on the page, the changes are already in view.
        guard count > 0, visibleVisits == 0, Settings.backgroundConnections.get(),
              Settings.listenerChangeNotifications.get() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Listener changes"
        content.body = ListenerReviewWords.changeCount(count) + " since you last reviewed. Open Connections to review them."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    func acceptListeners(_ identities: Set<ListenerIdentity>) async {
        guard !showsListenerFixture, !acceptingListeners else { return }
        acceptingListeners = true
        listenerAcceptance += 1
        defer { acceptingListeners = false }
        if let walkTask { _ = await walkTask.value }
        do {
            let review = try await historyWorker.acceptListeners(identities)
            if listenerReview != review { listenerReview = review }
            listenerError = nil
        } catch { listenerError = error.localizedDescription }
    }

    func requestListenerNotifications() {
        guard !showsListenerFixture else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
