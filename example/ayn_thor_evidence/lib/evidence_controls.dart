/// Debug-evidence-only, non-secret controls. This library must never be in the
/// ordinary entrypoint import graph.
final class EvidenceControls {
  Duration clockOffset = Duration.zero;
  bool forceNextRefreshInvalidGrant = false;
  bool seedMalformedRecord = false;
  JournalPausePhase? pauseAt;

  void reset() {
    clockOffset = Duration.zero;
    forceNextRefreshInvalidGrant = false;
    seedMalformedRecord = false;
    pauseAt = null;
  }
}

/// Persistable non-secret journal checkpoints used only by the evidence build.
enum JournalPausePhase {
  beforePendingWrite,
  afterPendingWrite,
  afterCommitWrite,
}
