import Foundation
import OSLog
import UserNotifications

/// The app's one `UNUserNotificationCenter` delegate.
///
/// macOS allows a single delegate per process, and more than one feature posts notifications
/// with actions on them. Each feature registers its own category here, with the handler for
/// that category's actions, instead of claiming the delegate for itself and silently taking
/// it away from every other feature.
///
/// Categories are kept and re-sent as a whole on every registration, because
/// `setNotificationCategories` replaces the set rather than adding to it.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// What the user did with a notification, copied out of the `UNNotificationResponse`.
    ///
    /// A copy rather than the response itself: the response is not `Sendable`, and the
    /// delegate is called off the main actor, so handing it over would not compile under
    /// strict concurrency.
    struct Answer: Sendable, Equatable {
        /// One of the category's action identifiers, or `UNNotificationDefaultActionIdentifier`
        /// (the notification was clicked) or `UNNotificationDismissActionIdentifier` (closed,
        /// for categories registered with `.customDismissAction`).
        let actionIdentifier: String
        let requestIdentifier: String

        /// The string-keyed, string-valued entries of the notification's `userInfo`. Anything
        /// a handler needs back has to be posted as a string.
        let userInfo: [String: String]
    }

    typealias Handler = @MainActor (Answer) -> Void

    private var categories: [String: UNNotificationCategory] = [:]
    private var handlers: [String: Handler] = [:]

    /// Nonisolated because `add`'s completion handler runs off the main actor. `Logger` is
    /// `Sendable`, so that is safe.
    private nonisolated static let log = Logger(subsystem: "com.leomarzo.tranlix", category: "notifications")

    private var center: UNUserNotificationCenter { .current() }

    /// Takes over as the center's delegate. The center holds its delegate weakly, so whoever
    /// calls this also has to keep this object alive.
    func becomeDelegate() {
        center.delegate = self
    }

    /// Adds a category and the handler for the actions on its notifications, replacing any
    /// earlier registration under the same identifier.
    func register(category: UNNotificationCategory, handler: @escaping Handler) {
        categories[category.identifier] = category
        handlers[category.identifier] = handler
        center.setNotificationCategories(Set(categories.values))
    }

    /// Asks once; afterwards reports what was decided. A denial is final from here: only the
    /// user can change it, in System Settings.
    func requestAuthorizationIfNeeded() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Posts, replacing a notification already delivered under the same identifier.
    func post(_ request: UNNotificationRequest) {
        let identifier = request.identifier
        center.add(request) { error in
            guard let error else { return }
            Self.log.error("Posting \(identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Withdraws notifications, whether still pending or already on screen.
    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even with Tranlix in front: these are questions, and the window that would
    /// answer them may be on another screen or behind the call. `.list` too, so a question
    /// that arrives while Tranlix is in front is still in Notification Center afterwards.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        let userInfo = request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        }
        let answer = Answer(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: request.identifier,
            userInfo: userInfo
        )
        await dispatch(answer, category: request.content.categoryIdentifier)
    }

    private func dispatch(_ answer: Answer, category: String) {
        guard let handler = handlers[category] else {
            Self.log.error("No handler for notification category \(category, privacy: .public)")
            return
        }
        handler(answer)
    }
}
