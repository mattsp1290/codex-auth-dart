import 'package:codex_auth/codex_auth.dart';

import 'sse_evidence_validator.dart';

/// Finite, token-free scenario state for the evidence host.
enum EvidenceState { idle, waitingForApproval, passed, failed, cancelled }

enum TupleEvidenceState {
  notRun,
  admitted,
  requestAccepted,
  executedIdentityVerified,
  blocked,
  failed,
}

/// Serializable only through its enum/category fields; no server text is held.
final class EvidenceEvent {
  const EvidenceEvent(this.scenario, this.state, {this.category});
  final String scenario;
  final EvidenceState state;
  final CodexAuthErrorCategory? category;
}

/// Owns the transient device-code UI state, never evidence serialization.
final class EvidenceController {
  EvidenceController(this._client);
  final CodexAuthClient _client;
  final List<void Function()> _listeners = <void Function()>[];
  CancellationController? _cancellation;

  EvidenceState state = EvidenceState.idle;
  DeviceLoginPrompt? prompt;
  EvidenceEvent event = const EvidenceEvent('device-login', EvidenceState.idle);
  final Map<String, TupleEvidenceState> tupleStates =
      <String, TupleEvidenceState>{
        'gpt-5.6-sol': TupleEvidenceState.notRun,
        'gpt-5.6-terra': TupleEvidenceState.notRun,
        'gpt-5.6-luna': TupleEvidenceState.notRun,
      };

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  Future<EvidenceEvent> startDeviceLogin() async {
    if (state == EvidenceState.waitingForApproval) return event;
    _cancellation = CancellationController();
    try {
      await _client.loginDevice(
        cancellation: _cancellation,
        onPrompt: (nextPrompt) {
          prompt = nextPrompt;
          state = EvidenceState.waitingForApproval;
          event = const EvidenceEvent(
            'device-login',
            EvidenceState.waitingForApproval,
          );
          _notify();
        },
      );
      prompt = null;
      state = EvidenceState.passed;
      event = const EvidenceEvent('device-login', EvidenceState.passed);
    } on OperationCancelled {
      prompt = null;
      state = EvidenceState.cancelled;
      event = const EvidenceEvent('device-login', EvidenceState.cancelled);
    } on CodexAuthException catch (error) {
      prompt = null;
      state = EvidenceState.failed;
      event = EvidenceEvent(
        'device-login',
        EvidenceState.failed,
        category: error.category,
      );
    } finally {
      _notify();
    }
    return event;
  }

  void cancel() => _cancellation?.cancel();

  Future<AuthStatus> status() => _client.status();

  /// Runs the three exact admissions and minimal streams after an explicit UI
  /// action. It stores only finite state, never response text or metadata.
  Future<Map<String, TupleEvidenceState>> runRequiredModels() async {
    try {
      final snapshot = await _client.listModels(const CatalogQuery('0.154.0'));
      for (final slug in tupleStates.keys.toList(growable: false)) {
        try {
          final admission = await _client.admitModel(snapshot, slug, 'medium');
          tupleStates[slug] = TupleEvidenceState.admitted;
          _notify();
          final stream = await _client.sendResponses(
            admission,
            CodexResponsesRequest(input: 'Reply with exactly OK.'),
          );
          tupleStates[slug] = TupleEvidenceState.requestAccepted;
          _notify();
          final validated = await const SseEvidenceValidator().validate(
            stream.bytes,
            expectedModel: slug,
            expectedEffort: 'medium',
          );
          await stream.close();
          tupleStates[slug] = switch (validated) {
            StreamEvidenceState.executedIdentityVerified =>
              TupleEvidenceState.executedIdentityVerified,
            StreamEvidenceState.blocked => TupleEvidenceState.blocked,
            StreamEvidenceState.failed => TupleEvidenceState.failed,
          };
        } on CodexAuthException {
          tupleStates[slug] = TupleEvidenceState.failed;
        }
        _notify();
      }
    } on CodexAuthException {
      for (final slug in tupleStates.keys) {
        if (tupleStates[slug] == TupleEvidenceState.notRun) {
          tupleStates[slug] = TupleEvidenceState.failed;
        }
      }
      _notify();
    }
    return Map<String, TupleEvidenceState>.unmodifiable(tupleStates);
  }
}
