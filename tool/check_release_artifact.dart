import 'dart:convert';
import 'dart:io';

const _evidenceFingerprint = 'codex-auth-evidence-entrypoint-v1';
const _ordinaryForbidden = <String>[
  _evidenceFingerprint,
  'evidence-command.json',
  'evidence-result.json',
  'evidence-checkpoint.json',
  'codex_auth/evidence_state_v1',
  'interrupt-after-refresh-risk',
  'interrupt-before-replacement-commit',
  'interrupt-after-replacement-commit',
  'invalid-grant',
];

/// Verifies flavor separation against compiled APK contents, not imports.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(arguments[0])) {
    throw ArgumentError(
      'usage: check_release_artifact.dart <package-commit> '
      '<ordinary-release.apk> <evidence-debug.apk>',
    );
  }
  final packageCommit = arguments[0];
  final ordinary = await _unpacked(arguments[1]);
  final evidence = await _unpacked(arguments[2]);
  await _verifyBadging(
    arguments[1],
    packageName: 'com.mattsp1290.codexauth.ayn_thor_evidence',
    launchActivity: 'com.mattsp1290.codexauth.ayn_thor_evidence.MainActivity',
  );
  await _verifyBadging(
    arguments[2],
    packageName: 'com.mattsp1290.codexauth.ayn_thor_evidence.evidence',
    launchActivity:
        'com.mattsp1290.codexauth.ayn_thor_evidence.EvidenceActivity',
  );
  if (!evidence.contains(_evidenceFingerprint)) {
    throw StateError('evidence APK lacks the expected entrypoint fingerprint');
  }
  if (!ordinary.contains(packageCommit) || !evidence.contains(packageCommit)) {
    throw StateError('APK package commit does not match the candidate');
  }
  if (_ordinaryForbidden.any(ordinary.contains)) {
    throw StateError('ordinary APK contains evidence-only content');
  }
}

Future<void> _verifyBadging(
  String apk, {
  required String packageName,
  required String launchActivity,
}) async {
  final result = await Process.run(_aapt(), <String>['dump', 'badging', apk]);
  if (result.exitCode != 0 || result.stdout is! String) {
    throw StateError('APK manifest cannot be inspected');
  }
  final badging = result.stdout as String;
  if (!badging.contains("package: name='$packageName' ") ||
      !badging.contains("launchable-activity: name='$launchActivity'")) {
    throw StateError(
      'APK flavor provenance does not match the expected target',
    );
  }
}

String _aapt() {
  for (final sdk in <String?>[
    Platform.environment['ANDROID_SDK_ROOT'],
    Platform.environment['ANDROID_HOME'],
  ]) {
    if (sdk == null || sdk.isEmpty) continue;
    final buildTools = Directory('$sdk${Platform.pathSeparator}build-tools');
    if (!buildTools.existsSync()) continue;
    final versions =
        buildTools
            .listSync()
            .whereType<Directory>()
            .map((directory) => directory.path)
            .toList()
          ..sort();
    for (final version in versions.reversed) {
      final candidate = File('$version${Platform.pathSeparator}aapt');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return 'aapt';
}

Future<String> _unpacked(String apk) async {
  final file = File(apk);
  if (!await file.exists()) throw StateError('APK missing');
  final result = await Process.run('unzip', <String>[
    '-p',
    file.path,
  ], stdoutEncoding: null);
  if (result.exitCode != 0) throw StateError('APK cannot be inspected');
  final bytes = result.stdout as List<int>;
  return latin1.decode(bytes, allowInvalid: true);
}
