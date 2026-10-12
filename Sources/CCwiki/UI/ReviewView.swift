import SwiftUI

/// A job's review in the Jobs window: what DiffGuard flagged, the diff,
/// rendered or as source, and the pull request it would open
/// (plans/corrections.md §6.6).
///
/// Phase 0: a placeholder. Track D builds the review (§11.5).
struct ReviewView: View {
    let job: Job

    var body: some View {
        ContentUnavailableView(
            "The Review Is Not Built Yet", systemImage: JobState.awaitingReview.symbolName,
            description: Text("Its changes, what DiffGuard flagged, and the pull request "
                + "CCwiki would open will show here."))
    }
}
