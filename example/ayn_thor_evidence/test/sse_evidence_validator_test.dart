import 'dart:convert';

import 'package:ayn_thor_evidence/sse_evidence_validator.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _sse(String value) =>
    Stream<List<int>>.value(utf8.encode(value));

void main() {
  const validator = SseEvidenceValidator();

  test(
    'requires exactly one terminal event and matching returned identity',
    () async {
      final state = await validator.validate(
        _sse(
          'event: response.completed\ndata: {"response":{"model":"gpt-5.6-sol","reasoning":{"effort":"medium"}}}\n\n',
        ),
        expectedModel: 'gpt-5.6-sol',
        expectedEffort: 'medium',
      );
      expect(state, StreamEvidenceState.executedIdentityVerified);
    },
  );

  test('missing returned identity is blocked rather than passed', () async {
    final state = await validator.validate(
      _sse('event: response.completed\ndata: {}\n\n'),
      expectedModel: 'gpt-5.6-sol',
      expectedEffort: 'medium',
    );
    expect(state, StreamEvidenceState.blocked);
  });

  test('post-terminal data and failed events are rejected', () async {
    final duplicate = await validator.validate(
      _sse(
        'event: response.completed\ndata: {"model":"gpt-5.6-sol","reasoning":{"effort":"medium"}}\n\nevent: response.completed\ndata: {}\n\n',
      ),
      expectedModel: 'gpt-5.6-sol',
      expectedEffort: 'medium',
    );
    final failed = await validator.validate(
      _sse('event: response.failed\ndata: {}\n\n'),
      expectedModel: 'gpt-5.6-sol',
      expectedEffort: 'medium',
    );
    expect(duplicate, StreamEvidenceState.failed);
    expect(failed, StreamEvidenceState.failed);
  });
}
