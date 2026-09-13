import 'package:codex_auth/codex_auth.dart';

/// Finite, token-free scenario state for the evidence host.
enum EvidenceState { idle, waitingForApproval, passed, failed, cancelled }

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

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  Future<void> startDeviceLogin() async {
    if (state == EvidenceState.waitingForApproval) return;
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
  }

  void cancel() => _cancellation?.cancel();
}
