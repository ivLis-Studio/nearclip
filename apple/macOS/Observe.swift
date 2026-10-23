import Foundation
import Observation

/// Re-runs `body` whenever any observable value it reads changes (for AppKit glue code).
@MainActor
func observeChanges(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
        body()
    } onChange: {
        DispatchQueue.main.async { observeChanges(body) }
    }
}

