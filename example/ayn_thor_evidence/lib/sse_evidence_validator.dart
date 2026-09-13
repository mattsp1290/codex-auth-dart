import 'dart:async';
import 'dart:convert';

/// Finite evidence result for one streamed Responses request.
enum StreamEvidenceState { executedIdentityVerified, blocked, failed }

/// Parses only bounded SSE metadata. Generated output is discarded immediately.
final class SseEvidenceValidator {
  const SseEvidenceValidator({
    this.maxLineBytes = 16 * 1024,
    this.maxEvents = 256,
  });

  final int maxLineBytes;
  final int maxEvents;

  Future<StreamEvidenceState> validate(
    Stream<List<int>> bytes, {
    required String expectedModel,
    required String expectedEffort,
  }) async {
    var eventName = '';
    String? data;
    var terminal = false;
    var terminalHasIdentity = false;
    var events = 0;
    try {
      await for (final line
          in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
        if (utf8.encode(line).length > maxLineBytes) {
          return StreamEvidenceState.failed;
        }
        if (line.isEmpty) {
          if (eventName.isEmpty && data == null) continue;
          events++;
          if (events > maxEvents || terminal) return StreamEvidenceState.failed;
          if (eventName == 'response.failed' ||
              eventName == 'response.incomplete' ||
              eventName == 'error') {
            return StreamEvidenceState.failed;
          }
          if (eventName == 'response.completed') {
            terminal = true;
            final identity = _identity(data);
            if (identity == null) continue;
            if (identity.$1 != expectedModel || identity.$2 != expectedEffort) {
              return StreamEvidenceState.failed;
            }
            terminalHasIdentity = true;
          }
          eventName = '';
          data = null;
          continue;
        }
        if (line.startsWith('event:')) {
          if (eventName.isNotEmpty || data != null) {
            return StreamEvidenceState.failed;
          }
          eventName = line.substring('event:'.length).trim();
        } else if (line.startsWith('data:')) {
          if (data != null) return StreamEvidenceState.failed;
          data = line.substring('data:'.length).trim();
        } else if (!line.startsWith(':')) {
          return StreamEvidenceState.failed;
        }
      }
    } on FormatException {
      return StreamEvidenceState.failed;
    }
    if (!terminal) return StreamEvidenceState.failed;
    // Missing authoritative identity is not a pass just because request
    // completion was observed; it is a live-protocol blocker.
    return terminalHasIdentity
        ? StreamEvidenceState.executedIdentityVerified
        : StreamEvidenceState.blocked;
  }

  (String, String)? _identity(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final response = decoded['response'];
      final source = response is Map<String, Object?> ? response : decoded;
      final model = source['model'];
      final reasoning = source['reasoning'];
      final effort = reasoning is Map<String, Object?>
          ? reasoning['effort']
          : null;
      return model is String && effort is String ? (model, effort) : null;
    } on FormatException {
      return null;
    }
  }
}
