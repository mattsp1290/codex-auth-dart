import 'dart:convert';
import 'dart:io';

const evidenceEntrypointFingerprint = 'codex-auth-evidence-entrypoint-v1';

const ordinaryForbiddenContent = <String>[
  evidenceEntrypointFingerprint,
  'evidence-command.json',
  'evidence-result.json',
  'evidence-checkpoint.json',
  'codex_auth/evidence_state_v1',
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
  'evidence-invalid-refresh-value',
  'rehydration-ready',
  'refresh-risk',
  'before-replacement',
  'after-replacement',
];

Future<void> verifyEvidenceArtifact(String packageCommit, String apk) async {
  _requireCommit(packageCommit);
  final unpacked = await _unpacked(apk);
  await _verifyBadging(
    apk,
    packageName: 'com.mattsp1290.codexauth.ayn_thor_evidence.evidence',
    launchActivity:
        'com.mattsp1290.codexauth.ayn_thor_evidence.EvidenceActivity',
  );
  if (!unpacked.contains(evidenceEntrypointFingerprint)) {
    throw StateError('evidence APK lacks the expected entrypoint fingerprint');
  }
  if (!unpacked.contains(packageCommit)) {
    throw StateError(
      'evidence APK package commit does not match the candidate',
    );
  }
}

Future<void> verifyReleaseArtifacts(
  String packageCommit,
  String ordinaryApk,
  String evidenceApk,
) async {
  _requireCommit(packageCommit);
  final ordinary = await _unpacked(ordinaryApk);
  await _verifyBadging(
    ordinaryApk,
    packageName: 'com.mattsp1290.codexauth.ayn_thor_evidence',
    launchActivity: 'com.mattsp1290.codexauth.ayn_thor_evidence.MainActivity',
  );
  await verifyEvidenceArtifact(packageCommit, evidenceApk);
  if (!ordinary.contains(packageCommit)) {
    throw StateError(
      'ordinary APK package commit does not match the candidate',
    );
  }
  if (ordinaryForbiddenContent.any(ordinary.contains)) {
    throw StateError('ordinary APK contains evidence-only content');
  }
}

void _requireCommit(String value) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
    throw ArgumentError('invalid package commit');
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
  return latin1.decode(result.stdout as List<int>, allowInvalid: true);
}
