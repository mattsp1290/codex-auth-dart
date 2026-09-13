import 'dart:io';

import 'package:test/test.dart';

import '../tool/run_ayn_thor_matrix.dart' as runner;
import 'run_ayn_thor_matrix_test.dart' show FakeAdapterForCli;

void main() {
  test('CLI emits one success only after engine cleanup', () async {
    final directory = await Directory.systemTemp.createTemp('matrix-cli-');
    addTearDown(() => directory.delete(recursive: true));
    final apk = File('${directory.path}/candidate.apk');
    await apk.writeAsBytes(<int>[1, 2, 3]);
    final out = StringBuffer();
    final err = StringBuffer();

    final code = await runner.runMatrixCli(
      <String>[
        '--package-commit',
        'a' * 40,
        '--apk',
        apk.path,
        '--scenario',
        'local-logout',
        '--confirm-destructive',
      ],
      environment: const <String, String>{'ANDROID_SERIAL': 'selected'},
      adapterFactory: (_, _) => FakeAdapterForCli(commit: 'a' * 40),
      stdoutSink: out,
      stderrSink: err,
    );

    expect(code, 0);
    expect(out.toString().trim().split('\n'), hasLength(1));
    expect(err.toString(), contains('matrix runner stage cleanup-clear'));
    expect(err.toString(), isNot(contains('matrix runner rejected')));
  });

  test(
    'CLI failure emits no success and authoritative closed labels',
    () async {
      final directory = await Directory.systemTemp.createTemp('matrix-cli-');
      addTearDown(() => directory.delete(recursive: true));
      final apk = File('${directory.path}/candidate.apk');
      await apk.writeAsBytes(<int>[1, 2, 3]);
      final out = StringBuffer();
      final err = StringBuffer();

      final code = await runner.runMatrixCli(
        <String>[
          '--package-commit',
          'a' * 40,
          '--apk',
          apk.path,
          '--scenario',
          'local-logout',
          '--confirm-destructive',
        ],
        environment: const <String, String>{'ANDROID_SERIAL': 'selected'},
        adapterFactory: (_, _) => FakeAdapterForCli(
          commit: 'a' * 40,
          invalidResult: true,
          failFinalClear: true,
        ),
        stdoutSink: out,
        stderrSink: err,
      );

      expect(code, 1);
      expect(out.toString(), isEmpty);
      expect(
        err.toString(),
        contains('matrix runner rejected at validate-result'),
      );
      expect(
        err.toString(),
        contains('matrix runner cleanup incomplete at cleanup-clear'),
      );
    },
  );
}
