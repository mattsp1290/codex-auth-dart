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
    await _run(arguments, (value) => stage = value);
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
  setStage('clear-previous-result');
  await runner.clearPreviousResult();
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
  setStage('launch');
  await runner.launch();
  setStage('finite-result');
  final raw = await runner.waitForResult(const Duration(minutes: 15));
  setStage('validate-result');
  final result = EvidenceSchema.validateRawResult(
    raw,
    scenario: options.scenario,
    packageCommit: options.packageCommit,
    nonce: nonce,
  );
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
}

final class _Options {
  const _Options(
    this.packageCommit,
    this.apk,
    this.scenario,
    this.confirmDestructive,
  );
  final String packageCommit;
  final String apk;
  final String scenario;
  final bool confirmDestructive;

  static _Options parse(List<String> arguments) {
    String? commit;
    String? apk;
    String? scenario;
    var confirmed = false;
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
    return _Options(commit, apk, scenario, confirmed);
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
        model.toLowerCase() != 'thor' ||
        release.isEmpty ||
        buildId.isEmpty ||
        fingerprint.isEmpty) {
      throw StateError('selected device does not match AYN Thor provenance');
    }
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
    final process = await Process.start(_adb, <String>[
      '-s',
      _serial,
      'exec-out',
      'run-as',
      _package,
      'sh',
      '-c',
      'cat > files/evidence-command.json',
    ]);
    process.stdin.write(command);
    await process.stdin.close();
    if (await process.exitCode != 0) {
      throw StateError('evidence command cannot be written');
    }
  }

  Future<void> clearPreviousResult() async {
    await _run(<String>[
      'exec-out',
      'run-as',
      _package,
      'rm',
      '-f',
      'files/evidence-result.json',
    ]);
  }

  Future<void> launch() async {
    await _run(<String>['shell', 'am', 'force-stop', _package]);
    await _run(<String>['shell', 'monkey', '-p', _package, '1']);
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
