import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'evidence_schema.dart';

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
  var stage = 'arguments';
  try {
    await _run(arguments, (value) {
      stage = value;
      stderr.writeln('matrix runner stage $value');
    });
  } on Object {
    // A closed stage label makes host/device failures diagnosable without
    // exposing command lines, local paths, serials, nonces, or raw records.
    stderr.writeln('matrix runner rejected at $stage');
    exitCode = 1;
  }
}

Future<void> _run(
  List<String> arguments,
  void Function(String stage) setStage,
) async {
  final options = _Options.parse(arguments);
  setStage('device-selection');
  final serial = Platform.environment['ANDROID_SERIAL'];
  if (serial == null || serial.isEmpty) {
    throw StateError('one authorized Android device must be selected');
  }
  final runner = _Adb(serial);
  setStage('physical-device');
  await runner.requirePhysicalDevice();
  if (_destructive.contains(options.scenario) && !options.confirmDestructive) {
    throw StateError('destructive scenario requires explicit confirmation');
  }
  final expectedDigest = await _sha256(File(options.apk));
  setStage('install');
  await runner.install(options.apk);
  setStage('installed-digest');
  if (!await runner.installedDigestMatches(expectedDigest)) {
    throw StateError('installed APK does not match candidate');
  }
  setStage('clear-previous-state');
  await runner.clearTransientState();
  _RedirectFixture? redirect;
  if (options.scenario == 'redirect-matrix') {
    setStage('redirect-fixture');
    redirect = await _RedirectFixture.start(runner);
  }
  final nonce = _nonce();
  final command = jsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'scenario': options.scenario,
    'packageCommit': options.packageCommit,
    'flavor': 'evidence',
    'nonce': nonce,
  });
  setStage('write-command');
  await runner.writeCommand(command);
  Object? primaryFailure;
  try {
    setStage('launch');
    await runner.launch();
    setStage('finite-result');
    final raw = await runner.waitForResult(options.resultTimeout);
    setStage('command-consumption');
    if (!await runner.commandWasConsumed()) {
      throw StateError('evidence command was not consumed');
    }
    setStage('validate-result');
    final result = EvidenceSchema.validateRawResult(
      raw,
      scenario: options.scenario,
      packageCommit: options.packageCommit,
      nonce: nonce,
    );
    if (redirect != null) {
      setStage('redirect-validation');
      await redirect.verify();
    }
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'device': 'ayn-thor',
        'scenario': options.scenario,
        'state': result['state'],
        'recovery': result['recovery'],
        'protectedIo': result['protectedIo'],
        if (result['category'] != null) 'category': result['category'],
      }),
    );
  } on Object catch (error) {
    primaryFailure = error;
    rethrow;
  } finally {
    try {
      setStage('cleanup-clear');
      await runner.clearTransientState();
      if (redirect != null) {
        setStage('cleanup-redirect');
        await redirect.close(runner);
      }
    } on Object {
      if (primaryFailure == null) rethrow;
    }
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

final class _Adb {
  _Adb(this._serial) : _adb = _resolveAdb();
  final String _serial;
  final String _adb;

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

  Future<void> install(String apk) async {
    if (!await File(apk).exists()) {
      throw StateError('evidence APK is unavailable');
    }
    await _run(<String>['install', '-r', apk]);
  }

  Future<bool> installedDigestMatches(String expected) async {
    final output = await _run(<String>['shell', 'pm', 'path', _package]);
    const prefix = 'package:';
    final path = output.trim();
    if (!path.startsWith(prefix) || path.length == prefix.length) return false;
    final apkPath = path.substring(prefix.length);
    final result = await Process.run(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'cat',
      apkPath,
    ], stdoutEncoding: null);
    if (result.exitCode != 0 || result.stdout is! List<int>) return false;
    return sha256.convert(result.stdout as List<int>).toString() == expected;
  }

  Future<void> writeCommand(String command) async {
    final encoded = base64Encode(utf8.encode(command));
    final result = await Process.run(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'run-as',
      _package,
      'sh',
      '-c',
      "printf %s '$encoded' | base64 -d > files/evidence-command.json",
    ]);
    if (result.exitCode != 0) {
      throw StateError('evidence command cannot be written');
    }
  }

  Future<void> clearTransientState() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _run(<String>[
          'exec-out',
          'run-as',
          _package,
          'rm',
          '-f',
          'files/evidence-command.json',
          'files/evidence-result.json',
          'files/evidence-result.json.tmp',
        ]);
        final files = await _run(<String>[
          'exec-out',
          'run-as',
          _package,
          'ls',
          'files',
        ]);
        if (!files
            .split(RegExp(r'\s+'))
            .any(
              <String>{
                'evidence-command.json',
                'evidence-result.json',
                'evidence-result.json.tmp',
              }.contains,
            )) {
          return;
        }
      } on Object {
        // The next bounded attempt decides whether app-private cleanup settled.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw StateError('transient evidence state cannot be cleared');
  }

  Future<bool> commandWasConsumed() async {
    final result = await Process.run(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'run-as',
      _package,
      'sh',
      '-c',
      'test ! -e files/evidence-command.json',
    ]);
    return result.exitCode == 0;
  }

  Future<void> reversePort(int port) =>
      _run(<String>['reverse', 'tcp:$port', 'tcp:$port']);

  Future<void> removeReversePort(int port) async {
    final result = await Process.run(_adb, <String>[
      '-s',
      _serial,
      'reverse',
      '--remove',
      'tcp:$port',
    ]);
    if (result.exitCode != 0) {
      throw StateError('redirect mapping cleanup failed');
    }
  }

  Future<void> launch() async {
    await _run(<String>['shell', 'am', 'force-stop', _package]);
    await _run(<String>[
      'shell',
      'am',
      'start',
      '-n',
      '$_package/com.mattsp1290.codexauth.ayn_thor_evidence.EvidenceActivity',
    ]);
  }

  Future<String> waitForResult(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run(_adb, <String>[
        '-s',
        _serial,
        'exec-out',
        'run-as',
        _package,
        'cat',
        'files/evidence-result.json',
      ]);
      if (result.exitCode == 0 &&
          result.stdout is String &&
          (result.stdout as String).isNotEmpty) {
        return result.stdout as String;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('finite evidence result timed out');
  }

  Future<String> _run(List<String> arguments) async {
    final result = await Process.run(_adb, <String>[
      '-s',
      _serial,
      ...arguments,
    ]);
    if (result.exitCode != 0) throw StateError('Android command failed');
    return result.stdout as String;
  }
}

final class _RedirectFixture {
  _RedirectFixture(this._process);
  static const _port = 8787;
  final Process _process;

  static Future<_RedirectFixture> start(_Adb adb) async {
    final toolDirectory = File.fromUri(Platform.script).parent;
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      '${toolDirectory.path}${Platform.pathSeparator}redirect_probe_server.dart',
      '$_port',
    ]);
    final fixture = _RedirectFixture(process);
    try {
      await fixture._awaitReady();
      await adb.reversePort(_port);
      return fixture;
    } on Object {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
      rethrow;
    }
  }

  Future<void> _awaitReady() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$_port/status'),
          );
          final response = await request.close();
          await response.drain<void>();
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

  Future<void> verify() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$_port/status'),
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('redirect status unavailable');
      }
      final value = jsonDecode(await utf8.decoder.bind(response).join());
      if (value is! Map || value['cases'] is! Map || value['target'] is! Map) {
        throw StateError('redirect status invalid');
      }
      final cases = Map<String, Object?>.from(value['cases'] as Map);
      if (cases.length != 25) throw StateError('redirect cases incomplete');
      _verifyStats(
        Map<String, Object?>.from(value['target'] as Map),
        const <String, bool>{},
      );
      for (final requestClass in _redirectShapes.entries) {
        for (final status in <int>[301, 302, 303, 307, 308]) {
          final stats = cases['${requestClass.key}-$status'];
          if (stats is! Map) throw StateError('redirect case missing');
          _verifyStats(Map<String, Object?>.from(stats), requestClass.value);
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close(_Adb adb) async {
    try {
      await adb.removeReversePort(_port);
    } finally {
      _process.kill(ProcessSignal.sigterm);
      await _process.exitCode;
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

  static void _verifyStats(
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
  final doctor = Process.runSync('flutter', <String>['doctor', '-v']);
  if (doctor.exitCode == 0 && doctor.stdout is String) {
    final match = RegExp(r'Android SDK at ([^\r\n]+)')
        .firstMatch(doctor.stdout as String);
    final root = match?.group(1)?.trim();
    if (root != null) {
      final candidate = File(
        '$root${Platform.pathSeparator}platform-tools${Platform.pathSeparator}adb',
      );
      if (candidate.existsSync()) return candidate.path;
    }
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
