import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/src/bounded_process_executor.dart';

void main() {
  test(
    'text execution caps retained output while draining the child',
    () async {
      final executor = const BoundedProcessExecutor(outputLimit: 8);
      final result = await executor.runText('/bin/sh', <String>[
        '-c',
        "printf '%s' 'abcdefghijklmnop'",
      ], timeout: const Duration(seconds: 2));

      expect(result.succeeded, isTrue);
      expect(result.stdoutText, 'abcdefgh');
    },
  );

  test('streaming digest requires the exact expected byte count', () async {
    const bytes = 'abcdef';
    final executor = const BoundedProcessExecutor();
    final result = await executor.runSha256(
      '/bin/sh',
      <String>['-c', "printf '%s' '$bytes'"],
      expectedBytes: bytes.length,
      timeout: const Duration(seconds: 2),
    );

    expect(result.succeeded, isTrue);
    expect(result.byteCount, bytes.length);
    expect(result.digest, sha256.convert(bytes.codeUnits).toString());
  });

  test(
    'timeout terminates a child that ignores graceful termination',
    () async {
      if (Platform.isWindows) return;
      final executor = const BoundedProcessExecutor(
        terminationGrace: Duration(milliseconds: 50),
        reapGrace: Duration(milliseconds: 200),
      );
      final stopwatch = Stopwatch()..start();
      final result = await executor.runText('/bin/sh', <String>[
        '-c',
        "trap '' TERM; while :; do :; done",
      ], timeout: const Duration(milliseconds: 100));

      expect(result.timedOut, isTrue);
      expect(result.reaped, isTrue);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );
}
