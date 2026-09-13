import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

final class BoundedProcessResult {
  const BoundedProcessResult({
    required this.exitCode,
    required this.stdoutText,
    required this.timedOut,
    required this.reaped,
  });

  final int? exitCode;
  final String stdoutText;
  final bool timedOut;
  final bool reaped;

  bool get succeeded => !timedOut && reaped && exitCode == 0;
}

final class StreamingDigestResult {
  const StreamingDigestResult({
    required this.exitCode,
    required this.digest,
    required this.byteCount,
    required this.timedOut,
    required this.reaped,
  });

  final int? exitCode;
  final String? digest;
  final int byteCount;
  final bool timedOut;
  final bool reaped;

  bool get succeeded => !timedOut && reaped && exitCode == 0;
}

final class BoundedProcessExecutor {
  const BoundedProcessExecutor({
    this.outputLimit = 64 * 1024,
    this.terminationGrace = const Duration(seconds: 1),
    this.reapGrace = const Duration(seconds: 1),
  });

  final int outputLimit;
  final Duration terminationGrace;
  final Duration reapGrace;

  Future<BoundedProcessResult> runText(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    final process = await Process.start(executable, arguments).timeout(timeout);
    final stdoutCollector = _TextCollector(process.stdout, outputLimit);
    final stderrCollector = _TextCollector(process.stderr, outputLimit);
    final termination = await _wait(process, timeout);
    await stdoutCollector.finish(reapGrace);
    await stderrCollector.finish(reapGrace);
    return BoundedProcessResult(
      exitCode: termination.exitCode,
      stdoutText: stdoutCollector.text,
      timedOut: termination.timedOut,
      reaped: termination.reaped,
    );
  }

  Future<StreamingDigestResult> runSha256(
    String executable,
    List<String> arguments, {
    required int expectedBytes,
    required Duration timeout,
  }) async {
    final process = await Process.start(executable, arguments).timeout(timeout);
    final digestCollector = _DigestCollector(process.stdout, expectedBytes);
    final stderrCollector = _TextCollector(process.stderr, outputLimit);
    final termination = await _wait(process, timeout);
    await digestCollector.finish(reapGrace);
    await stderrCollector.finish(reapGrace);
    return StreamingDigestResult(
      exitCode: termination.exitCode,
      digest: digestCollector.digest,
      byteCount: digestCollector.byteCount,
      timedOut: termination.timedOut,
      reaped: termination.reaped,
    );
  }

  Future<_Termination> _wait(Process process, Duration timeout) async {
    try {
      return _Termination(await process.exitCode.timeout(timeout), false, true);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        return _Termination(
          await process.exitCode.timeout(terminationGrace),
          true,
          true,
        );
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        try {
          return _Termination(
            await process.exitCode.timeout(reapGrace),
            true,
            true,
          );
        } on TimeoutException {
          return const _Termination(null, true, false);
        }
      }
    }
  }
}

final class _TextCollector {
  _TextCollector(Stream<List<int>> stream, this.limit) {
    _subscription = stream.listen(
      (chunk) {
        final remaining = limit - _bytes.length;
        if (remaining > 0) _bytes.addAll(chunk.take(remaining));
      },
      onDone: _done.complete,
      onError: (Object error, StackTrace stackTrace) =>
          _done.completeError(error, stackTrace),
    );
  }

  final int limit;
  final _bytes = <int>[];
  final _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  String get text => utf8.decode(_bytes, allowMalformed: true);

  Future<void> finish(Duration timeout) async {
    try {
      await _done.future.timeout(timeout);
    } on Object {
      await _subscription.cancel();
    }
  }
}

final class _DigestCollector {
  _DigestCollector(Stream<List<int>> stream, this.expectedBytes) {
    final sink = sha256.startChunkedConversion(_DigestSink(_completeDigest));
    _subscription = stream.listen(
      (chunk) {
        byteCount += chunk.length;
        if (byteCount > expectedBytes) {
          _invalid = true;
        } else {
          sink.add(chunk);
        }
      },
      onDone: () {
        sink.close();
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        _invalid = true;
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  final int expectedBytes;
  final _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;
  String? _digest;
  bool _invalid = false;
  int byteCount = 0;

  String? get digest =>
      !_invalid && byteCount == expectedBytes ? _digest : null;

  void _completeDigest(Digest value) => _digest = value.toString();

  Future<void> finish(Duration timeout) async {
    try {
      await _done.future.timeout(timeout);
    } on Object {
      _invalid = true;
      await _subscription.cancel();
    }
  }
}

final class _DigestSink implements Sink<Digest> {
  const _DigestSink(this.onDigest);
  final void Function(Digest digest) onDigest;

  @override
  void add(Digest data) => onDigest(data);

  @override
  void close() {}
}

final class _Termination {
  const _Termination(this.exitCode, this.timedOut, this.reaped);
  final int? exitCode;
  final bool timedOut;
  final bool reaped;
}
