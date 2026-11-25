// ZTAT-PATCH: Removed Sparkle user-driver dependency; kept harmless no-op type.
import Foundation

final class UpdateFallbackUserDriver: NSObject {
    var shouldSuppressUpdaterError: ((Error) -> Bool)?

    private let presentUpdaterError: ((Error, @escaping () -> Void) -> Void)?

    init(
        hostBundle _: Bundle = .main,
        delegate _: AnyObject? = nil,
        presentUpdaterError: ((Error, @escaping () -> Void) -> Void)? = nil
    ) {
        self.presentUpdaterError = presentUpdaterError
        super.init()
    }

    func showUpdaterError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }
}
