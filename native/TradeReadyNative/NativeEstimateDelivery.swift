import Foundation

enum NativeMessageComposeOutcome: Equatable, Sendable {
    case sent
    case cancelled
    case saved
    case failed
}

enum NativeEstimateDeliveryResolution: Equatable, Sendable {
    case recordDelivery
    case keepReview
    case keepReviewWithSavedDraftNotice
    case keepReviewWithFailureNotice
}

enum NativeEstimateDeliveryRecordOutcome: Equatable, Sendable {
    case recorded
    case preservedNewerState
    case failed
}

enum NativeEstimateDeliveryPolicy {
    static func resolution(for outcome: NativeMessageComposeOutcome) -> NativeEstimateDeliveryResolution {
        switch outcome {
        case .sent: .recordDelivery
        case .cancelled: .keepReview
        case .saved: .keepReviewWithSavedDraftNotice
        case .failed: .keepReviewWithFailureNotice
        }
    }
}
