import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'src/ayn_thor_matrix_adapter.dart';
import 'src/ayn_thor_matrix_engine.dart';
import 'src/bounded_process_executor.dart';
import 'src/release_artifact_verifier.dart';

const _package = 'com.mattsp1290.codexauth.ayn_thor_evidence.evidence';
const _scenarios = <String>{
  'approved-login',
  'cancel-login',
  'declined-login',
  'expired-login',
  'rehydrate-after-resume',
  'rehydrate-after-process-death',
  'two-client-rotation',
  'interrupt-after-refresh-risk',
  'interrupt-before-replacement-commit',
  'interrupt-after-replacement-commit',
  'invalid-grant',
  'expired-without-refresh',
  'malformed-store',
  'unavailable-tuple',
  'exact-models',
  'redirect-matrix',
  'local-logout',
};
const _destructive = <String>{
  'interrupt-after-refresh-risk',
  'interrupt-before-replacement-commit',
  'interrupt-after-replacement-commit',
  'invalid-grant',
  'expired-without-refresh',
  'malformed-store',
  'local-logout',
};

/// Drives a single app-private finite evidence command without emitting a
/// serial, PID, app-private path, nonce, or raw result.
Future<void> main(List<String> arguments) async {
  exitCode = await runMatrixCli(arguments);
}

typedef MatrixAdapterFactory = AynThorMatrixAdapter Function(
  String serial,
  String apk,
);
typedef EvidenceArtifactValidator = Future<void> Function(
  String packageCommit,
  String apk,
);

Future<int> runMatrixCli(
  List<String> arguments, {
  MatrixAdapterFactory? adapterFactory,
  EvidenceArtifactValidator? artifactValidator,
  Map<String, String>? environment,
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) async {
  final out = stdoutSink ?? stdout;
  final err = stderrSink ?? stderr;
  try {
    final options = _Options.parse(arguments);
    err.writeln('matrix runner stage ${MatrixStage.artifactProvenance.label}');
    try {
      await (artifactValidator ?? verifyEvidenceArtifact)(
        options.packageCommit,
        options.apk,
      );
    } on Object {
      throw const MatrixRunFailure(
        primaryStage: MatrixStage.artifactProvenance,
      );
    }
    err.writeln('matrix runner stage ${MatrixStage.deviceSelection.label}');
    final serial = (environment ?? Platform.environment)['ANDROID_SERIAL'];
    if (serial == null || serial.isEmpty) {
      throw const MatrixRunFailure(primaryStage: MatrixStage.deviceSelection);
    }
    if (_destructive.contains(options.scenario) &&
        !options.confirmDestructive) {
      throw const MatrixRunFailure(primaryStage: MatrixStage.arguments);
    }
    final apk = File(options.apk);
    final expectedDigest = await _sha256(apk);
    final expectedBytes = await apk.length();
    final result = await runAynThorMatrixEngine(
      request: MatrixRunRequest(
        scenario: options.scenario,
        packageCommit: options.packageCommit,
        expectedDigest: expectedDigest,
        expectedApkBytes: expectedBytes,
        nonce: _nonce(),
        resultTimeout: options.resultTimeout,
      ),
      adapter: (adapterFactory ?? _Adb.new)(serial, options.apk),
      reportProgress: (stage) => err.writeln('matrix runner stage $stage'),
    );
    out.writeln(result.safeJson);
    return 0;
  } on MatrixRunFailure catch (failure) {
    err.writeln('matrix runner rejected at ${failure.rejectionLabel}');
    if (failure.validationRejection != null) {
      err.writeln(
        'matrix runner validation rejected at '
        '${failure.validationRejection!.label}',
      );
    }
    if (failure.primaryStage != null && failure.cleanupStage != null) {
      err.writeln(
        'matrix runner cleanup incomplete at ${failure.cleanupStage!.label}',
      );
    }
    return 1;
  } on Object {
    err.writeln('matrix runner rejected at ${MatrixStage.arguments.label}');
    return 1;
  }
}

final class _Options {
  const _Options(
    this.packageCommit,
    this.apk,
    this.scenario,
    this.confirmDestructive,
    this.resultTimeout,
  );
  final String packageCommit;
  final String apk;
  final String scenario;
  final bool confirmDestructive;
  final Duration resultTimeout;

  static _Options parse(List<String> arguments) {
    String? commit;
    String? apk;
    String? scenario;
    var confirmed = false;
    var resultTimeout = const Duration(minutes: 15);
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--package-commit':
          commit = arguments[++index];
        case '--apk':
          apk = arguments[++index];
        case '--scenario':
          scenario = arguments[++index];
        case '--confirm-destructive':
          confirmed = true;
        case '--result-timeout-seconds':
          final seconds = int.tryParse(arguments[++index]);
          if (seconds == null || seconds < 1 || seconds > 900) {
            throw ArgumentError('invalid matrix runner timeout');
          }
          resultTimeout = Duration(seconds: seconds);
        default:
          throw ArgumentError('invalid matrix runner argument');
      }
    }
    if (commit == null ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) ||
        apk == null ||
        scenario == null ||
        !_scenarios.contains(scenario)) {
      throw ArgumentError('invalid matrix runner configuration');
    }
    return _Options(commit, apk, scenario, confirmed, resultTimeout);
  }
}

final class _Adb implements AynThorMatrixAdapter {
  _Adb(this._serial, this._apk)
    : _adb = _resolveAdb(),
      _executor = const BoundedProcessExecutor();
  final String _serial;
  final String _apk;
  final String _adb;
  final BoundedProcessExecutor _executor;
  static const _commandTimeout = Duration(seconds: 30);

  @override
  Future<void> requirePhysicalDevice() async {
    final state = await _run(<String>['get-state']);
    if (state.trim() != 'device') {
      throw StateError('selected Android device is unavailable');
    }
    final emulator = await _run(<String>['shell', 'getprop', 'ro.kernel.qemu']);
    if (emulator.trim() == '1') {
      throw StateError('emulators are not evidence devices');
    }
    final manufacturer = await _property('ro.product.manufacturer');
    final model = await _property('ro.product.model');
    final release = await _property('ro.build.version.release');
    final buildId = await _property('ro.build.id');
    final fingerprint = await _property('ro.build.fingerprint');
    if (manufacturer.toLowerCase() != 'ayn' ||
        !_isAynThorModel(model) ||
        release.isEmpty ||
        buildId.isEmpty ||
        fingerprint.isEmpty) {
      throw StateError('selected device does not match AYN Thor provenance');
    }
  }

  bool _isAynThorModel(String model) {
    final normalized = model.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return normalized == 'thor' || normalized == 'ayn thor';
  }

  Future<String> _property(String name) async =>
      (await _run(<String>['shell', 'getprop', name])).trim();

  @override
  Future<void> install() async {
    if (!await File(_apk).exists()) {
      throw StateError('evidence APK is unavailable');
    }
    await _run(<String>[
      'install',
      '-r',
      _apk,
    ], timeout: const Duration(minutes: 2));
  }

  @override
  Future<bool> installedDigestMatches(
    String expected,
    int expectedBytes,
  ) async {
    final output = await _run(<String>['shell', 'pm', 'path', _package]);
    const prefix = 'package:';
    final path = output.trim();
    if (!path.startsWith(prefix) || path.length == prefix.length) return false;
    final apkPath = path.substring(prefix.length);
    final result = await _executor.runSha256(
      _adb,
      <String>['-s', _serial, 'exec-out', 'cat', apkPath],
      expectedBytes: expectedBytes,
      timeout: const Duration(minutes: 2),
    );
    return result.succeeded &&
        result.byteCount == expectedBytes &&
        result.digest == expected;
  }

  @override
  Future<void> writeCommand(String command) async {
    final encoded = base64Encode(utf8.encode(command));
    final result = await _executor.runText(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'run-as',
      _package,
      'sh',
      '-c',
      "printf %s '$encoded' | base64 -d > files/evidence-command.json",
    ], timeout: _commandTimeout);
    if (!result.succeeded) {
      throw StateError('evidence command cannot be written');
    }
  }

  @override
  Future<void> clearTransientState() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        // `adb shell` reconstructs a remote command string and can split the
        // fixed `sh -c` expression before the app UID receives it. `exec-out`
        // preserves this argument boundary, as the command-write path does.
        final result = await _executor.runText(_adb, <String>[
          '-s',
          _serial,
          'exec-out',
          'run-as',
          _package,
          'sh',
          '-c',
          'rm -f files/evidence-command.json files/evidence-result.json '
              'files/evidence-result.json.tmp files/evidence-checkpoint.json '
              'files/evidence-checkpoint.json.tmp && '
              'test ! -e files/evidence-command.json && '
              'test ! -e files/evidence-result.json && '
              'test ! -e files/evidence-result.json.tmp && '
              'test ! -e files/evidence-checkpoint.json && '
              'test ! -e files/evidence-checkpoint.json.tmp',
        ], timeout: _commandTimeout);
        if (!result.succeeded) {
          throw StateError('transient evidence state cannot be cleared');
        }
        return;
      } on Object {
        // The next bounded attempt decides whether app-private cleanup settled.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('transient evidence state cannot be cleared');
  }

  @override
  Future<bool> commandWasConsumed() async {
    final result = await _executor.runText(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'run-as',
      _package,
      'sh',
      '-c',
      'test ! -e files/evidence-command.json',
    ], timeout: _commandTimeout);
    return result.succeeded;
  }

  @override
  Future<void> reverseRedirectPort() => _run(<String>[
    'reverse',
    'tcp:${_RedirectFixture.port}',
    'tcp:${_RedirectFixture.port}',
  ]);

  @override
  Future<void> removeReverseRedirectPort() async {
    final result = await _executor.runText(_adb, <String>[
      '-s',
      _serial,
      'reverse',
      '--remove',
      'tcp:${_RedirectFixture.port}',
    ], timeout: _commandTimeout);
    if (!result.succeeded) {
      throw StateError('redirect mapping cleanup failed');
    }
  }

  @override
  Future<void> launch() async {
    await stop();
    await _run(<String>[
      'shell',
      'am',
      'start',
      '-n',
      '$_package/com.mattsp1290.codexauth.ayn_thor_evidence.EvidenceActivity',
    ]);
  }

  @override
  Future<void> backgroundAndResume() async {
    await _run(<String>['shell', 'input', 'keyevent', 'KEYCODE_HOME']);
    await Future<void>.delayed(const Duration(seconds: 1));
    await _run(<String>[
      'shell',
      'am',
      'start',
      '-n',
      '$_package/com.mattsp1290.codexauth.ayn_thor_evidence.EvidenceActivity',
    ]);
  }

  @override
  Future<String> processIdentity(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final result = await _executor.runText(_adb, <String>[
        '-s',
        _serial,
        'shell',
        'pidof',
        _package,
      ], timeout: _commandTimeout);
      final value = result.stdoutText.trim();
      if (result.succeeded && value.isNotEmpty) return value;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('evidence process unavailable');
  }

  @override
  Future<void> waitForCheckpoint(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final result = await _executor.runText(_adb, <String>[
        '-s',
        _serial,
        'exec-out',
        'run-as',
        _package,
        'sh',
        '-c',
        'test -s files/evidence-checkpoint.json && '
            'cat files/evidence-checkpoint.json',
      ], timeout: _commandTimeout);
      if (result.succeeded && isFiniteResultCandidate(result.stdoutText)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('durable evidence checkpoint timed out');
  }

  @override
  Future<void> stop() => _run(<String>['shell', 'am', 'force-stop', _package]);

  @override
  Future<String> waitForResult(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final result = await _executor.runText(_adb, <String>[
        '-s',
        _serial,
        'exec-out',
        'run-as',
        _package,
        'sh',
        '-c',
        'test -s files/evidence-result.json && '
            'cat files/evidence-result.json',
      ], timeout: _commandTimeout);
      if (result.succeeded && isFiniteResultCandidate(result.stdoutText)) {
        return result.stdoutText;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('finite evidence result timed out');
  }

  Future<String> _run(
    List<String> arguments, {
    Duration timeout = _commandTimeout,
  }) async {
    final result = await _executor.runText(_adb, <String>[
      '-s',
      _serial,
      ...arguments,
    ], timeout: timeout);
    if (!result.succeeded) throw StateError('Android command failed');
    return result.stdoutText;
  }

  @override
  Future<MatrixRedirectFixture> startRedirectFixture() =>
      _RedirectFixture.start();

  @override
  Future<void> cleanupSettleDelay() =>
      Future<void>.delayed(const Duration(seconds: 2));
}

final class _RedirectFixture implements MatrixRedirectFixture {
  _RedirectFixture(this._process);
  static const port = 8787;
  final Process _process;

  static Future<_RedirectFixture> start() async {
    final toolDirectory = File.fromUri(Platform.script).parent;
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      '${toolDirectory.path}${Platform.pathSeparator}redirect_probe_server.dart',
      '$port',
    ]);
    return _RedirectFixture(process);
  }

  @override
  Future<void> awaitReady() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/status'))
              .timeout(const Duration(seconds: 2));
          final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
          await response.drain<void>().timeout(const Duration(seconds: 2));
          if (response.statusCode == HttpStatus.ok) return;
        } finally {
          client.close(force: true);
        }
      } on Object {
        // The next bounded probe decides whether startup succeeded.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('redirect fixture did not start');
  }

  @override
  Future<List<Map<String, Object?>>> verify() async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/status'))
          .timeout(const Duration(seconds: 2));
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('redirect status unavailable');
      }
      final value = jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 2)),
      );
      if (value is! Map || value['cases'] is! Map || value['target'] is! Map) {
        throw StateError('redirect status invalid');
      }
      final cases = Map<String, Object?>.from(value['cases'] as Map);
      if (cases.length != 25) throw StateError('redirect cases incomplete');
      final targetShape = _verifyStats(
        Map<String, Object?>.from(value['target'] as Map),
        const <String, bool>{},
      );
      final rows = <Map<String, Object?>>[];
      for (final requestClass in _redirectShapes.entries) {
        for (final status in <int>[301, 302, 303, 307, 308]) {
          final stats = cases['${requestClass.key}-$status'];
          if (stats is! Map) throw StateError('redirect case missing');
          final sourceShape = _verifyStats(
            Map<String, Object?>.from(stats),
            requestClass.value,
          );
          rows.add(<String, Object?>{
            'requestClass': requestClass.key,
            'status': status,
            'sourceHits': 1,
            'targetHits': 0,
            'sourceShape': sourceShape,
            'targetShape': targetShape,
            'peerClosed': true,
          });
        }
      }
      return rows;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> close() async {
    _process.kill(ProcessSignal.sigterm);
    try {
      await _process.exitCode.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode.timeout(const Duration(seconds: 1));
    }
  }

  static const _redirectShapes = <String, Map<String, bool>>{
    'device-json': {
      'authorization': false,
      'deviceAuthId': true,
      'userCode': true,
      'authorizationCode': false,
      'refreshToken': false,
    },
    'authorization-code-form': {
      'authorization': false,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': true,
      'refreshToken': false,
    },
    'refresh-token-form': {
      'authorization': false,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': true,
    },
    'catalog-bearer': {
      'authorization': true,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': false,
    },
    'responses-bearer': {
      'authorization': true,
      'deviceAuthId': false,
      'userCode': false,
      'authorizationCode': false,
      'refreshToken': false,
    },
  };

  static Map<String, Object?> _verifyStats(
    Map<String, Object?> value,
    Map<String, bool> expected,
  ) {
    if (value['hits'] != (expected.isEmpty ? 0 : 1) || value['shape'] is! Map) {
      throw StateError('redirect counters invalid');
    }
    final shape = Map<String, Object?>.from(value['shape'] as Map);
    if (shape.length != 5 ||
        shape.entries.any(
          (entry) => entry.value != (expected[entry.key] ?? false),
        )) {
      throw StateError('redirect credential shape invalid');
    }
    return shape;
  }
}

String _resolveAdb() {
  for (final root in <String?>[
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['ANDROID_HOME'],
  ]) {
    if (root == null || root.isEmpty) continue;
    final candidate = File(
      '$root${Platform.pathSeparator}platform-tools${Platform.pathSeparator}adb',
    );
    if (candidate.existsSync()) return candidate.path;
  }
  return 'adb';
}

String _nonce() => List<int>.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Future<String> _sha256(File file) async {
  if (!await file.exists()) throw StateError('evidence APK is unavailable');
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
