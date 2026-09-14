import 'dart:convert';

import 'package:test/test.dart';

import '../tool/src/ayn_thor_matrix_engine.dart';

void main() {
  const commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const nonce =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

  MatrixRunRequest request({String scenario = 'local-logout'}) =>
      MatrixRunRequest(
        scenario: scenario,
        packageCommit: commit,
        expectedDigest: 'digest',
        expectedApkBytes: 3,
        nonce: nonce,
        resultTimeout: const Duration(seconds: 1),
      );

  test('success is returned only after mandatory cleanup', () async {
    final adapter = FakeAdapterForCli(commit: commit, nonce: nonce);
    final progress = <String>[];

    final result = await runAynThorMatrixEngine(
      request: request(),
      adapter: adapter,
      reportProgress: progress.add,
    );

    expect(jsonDecode(result.safeJson), containsPair('state', 'pass'));
    expect(adapter.calls.sublist(adapter.calls.length - 3), <String>[
      'stop',
      'settle',
      'clear',
    ]);
    expect(progress.last, CleanupStage.clear.label);
  });

  test('primary stage remains authoritative when cleanup succeeds', () async {
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      rawResult: '{}',
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>()
            .having(
              (failure) => failure.primaryStage,
              'primaryStage',
              MatrixStage.validateResult,
            )
            .having((failure) => failure.cleanupStage, 'cleanupStage', isNull),
      ),
    );
  });

  test('cleanup-only failure rejects at cleanup stage', () async {
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      failClearCall: 2,
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>()
            .having((failure) => failure.primaryStage, 'primaryStage', isNull)
            .having(
              (failure) => failure.cleanupStage,
              'cleanupStage',
              CleanupStage.clear,
            ),
      ),
    );
  });

  test('combined failure preserves primary and cleanup stages', () async {
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      rawResult: '{}',
      failClearCall: 2,
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>()
            .having(
              (failure) => failure.primaryStage,
              'primaryStage',
              MatrixStage.validateResult,
            )
            .having(
              (failure) => failure.cleanupStage,
              'cleanupStage',
              CleanupStage.clear,
            ),
      ),
    );
  });

  test('redirect cleanup continues after earlier cleanup failures', () async {
    final fixture = _FakeFixture(failClose: true);
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      fixture: fixture,
      failStop: true,
      failClearCall: 2,
      failRemoveReverse: true,
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(scenario: 'redirect-matrix'),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>().having(
          (failure) => failure.cleanupStage,
          'first cleanup stage',
          CleanupStage.stop,
        ),
      ),
    );
    expect(
      adapter.calls,
      containsAll(<String>['stop', 'clear', 'removeReverse']),
    );
    expect(fixture.closed, isTrue);
  });

  test(
    'a command side effect followed by failure still clears state',
    () async {
      final adapter = FakeAdapterForCli(
        commit: commit,
        nonce: nonce,
        failWriteAfterSideEffect: true,
      );

      await expectLater(
        runAynThorMatrixEngine(
          request: request(),
          adapter: adapter,
          reportProgress: (_) {},
        ),
        throwsA(
          isA<MatrixRunFailure>().having(
            (failure) => failure.primaryStage,
            'primaryStage',
            MatrixStage.writeCommand,
          ),
        ),
      );
      expect(adapter.calls.where((call) => call == 'clear'), hasLength(2));
    },
  );

  test('a reverse side effect followed by failure is still removed', () async {
    final fixture = _FakeFixture();
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      fixture: fixture,
      failReverseAfterSideEffect: true,
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(scenario: 'redirect-matrix'),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>().having(
          (failure) => failure.primaryStage,
          'primaryStage',
          MatrixStage.redirectFixture,
        ),
      ),
    );
    expect(adapter.calls, contains('removeReverse'));
    expect(fixture.closed, isTrue);
  });

  test(
    'interruption relaunch requires and records process replacement',
    () async {
      final adapter = FakeAdapterForCli(
        commit: commit,
        nonce: nonce,
        processIdentities: <String>['first-process', 'second-process'],
      );

      await runAynThorMatrixEngine(
        request: request(scenario: 'interrupt-after-refresh-risk'),
        adapter: adapter,
        reportProgress: (_) {},
      );

      expect(adapter.calls, containsAll(<String>['checkpoint', 'process']));
      expect(adapter.calls.where((call) => call == 'launch'), hasLength(2));
    },
  );

  test('interruption rejects a relaunch in the same process', () async {
    final adapter = FakeAdapterForCli(
      commit: commit,
      nonce: nonce,
      processIdentities: <String>['same-process', 'same-process'],
    );

    await expectLater(
      runAynThorMatrixEngine(
        request: request(scenario: 'interrupt-after-refresh-risk'),
        adapter: adapter,
        reportProgress: (_) {},
      ),
      throwsA(
        isA<MatrixRunFailure>().having(
          (failure) => failure.primaryStage,
          'primaryStage',
          MatrixStage.processRelaunch,
        ),
      ),
    );
    expect(adapter.calls, contains('clear'));
  });
}

final class FakeAdapterForCli implements AynThorMatrixAdapter {
  FakeAdapterForCli({
    required this.commit,
    this.nonce = '',
    String? rawResult,
    bool invalidResult = false,
    bool failFinalClear = false,
    int? failClearCall,
    this.failStop = false,
    this.failRemoveReverse = false,
    this.failWriteAfterSideEffect = false,
    this.failReverseAfterSideEffect = false,
    List<String>? processIdentities,
    MatrixRedirectFixture? fixture,
  }) : rawResult = invalidResult ? '{}' : rawResult,
       failClearCall = failFinalClear ? 2 : failClearCall,
       processIdentities = processIdentities ?? <String>['process'],
       fixture = fixture ?? _FakeFixture();

  final String commit;
  String nonce;
  String? rawResult;
  final int? failClearCall;
  final bool failStop;
  final bool failRemoveReverse;
  final bool failWriteAfterSideEffect;
  final bool failReverseAfterSideEffect;
  final MatrixRedirectFixture fixture;
  final List<String> processIdentities;
  final calls = <String>[];
  var _clearCalls = 0;
  var _scenario = 'local-logout';

  @override
  Future<void> requirePhysicalDevice() async => calls.add('physical');

  @override
  Future<void> install() async => calls.add('install');

  @override
  Future<bool> installedDigestMatches(
    String expected,
    int expectedBytes,
  ) async {
    calls.add('digest');
    return true;
  }

  @override
  Future<void> clearTransientState() async {
    calls.add('clear');
    _clearCalls++;
    if (_clearCalls == failClearCall) throw StateError('closed fake failure');
  }

  @override
  Future<MatrixRedirectFixture> startRedirectFixture() async {
    calls.add('fixture');
    return fixture;
  }

  @override
  Future<void> reverseRedirectPort() async {
    calls.add('reverse');
    if (failReverseAfterSideEffect) throw StateError('closed fake failure');
  }

  @override
  Future<void> removeReverseRedirectPort() async {
    calls.add('removeReverse');
    if (failRemoveReverse) throw StateError('closed fake failure');
  }

  @override
  Future<void> writeCommand(String command) async {
    calls.add('write');
    final value = jsonDecode(command) as Map<String, Object?>;
    _scenario = value['scenario']! as String;
    nonce = value['nonce']! as String;
    if (failWriteAfterSideEffect) throw StateError('closed fake failure');
  }

  @override
  Future<void> launch() async => calls.add('launch');

  @override
  Future<String> processIdentity(Duration timeout) async {
    calls.add('process');
    return processIdentities.removeAt(0);
  }

  @override
  Future<void> waitForCheckpoint(Duration timeout) async {
    calls.add('checkpoint');
  }

  @override
  Future<String> waitForResult(Duration timeout) async {
    calls.add('result');
    return rawResult ??
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'scenario': _scenario,
          'packageCommit': commit,
          'flavor': 'evidence',
          'nonce': nonce,
          'state': 'pass',
          'recovery': 'signed-out',
          'protectedIo': 0,
          'predicates': _passingPredicates(_scenario),
        });
  }

  @override
  Future<bool> commandWasConsumed() async {
    calls.add('consumed');
    return true;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (failStop) throw StateError('closed fake failure');
  }

  @override
  Future<void> cleanupSettleDelay() async => calls.add('settle');
}

Map<String, Object?> _passingPredicates(String scenario) => switch (scenario) {
  'interrupt-after-refresh-risk' => <String, Object?>{
    'refreshRiskAcknowledged': true,
    'processChanged': false,
    'oldStateCleared': true,
    'zeroProtectedIoBeforeResolution': true,
    'reauthenticated': true,
    'freshClient': true,
  },
  'local-logout' => <String, Object?>{
    'clearAcknowledged': true,
    'signedOut': true,
    'noRemoteRevocation': true,
  },
  _ => <String, Object?>{},
};

final class _FakeFixture implements MatrixRedirectFixture {
  _FakeFixture({this.failClose = false});
  final bool failClose;
  var closed = false;

  @override
  Future<void> awaitReady() async {}

  @override
  Future<void> verify() async {}

  @override
  Future<void> close() async {
    closed = true;
    if (failClose) throw StateError('closed fake failure');
  }
}
