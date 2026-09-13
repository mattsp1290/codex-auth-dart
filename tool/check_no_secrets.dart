import 'dart:io';

/// Refuses credential-shaped or identifying content in repository evidence.
/// Match values are deliberately never printed.
Future<void> main() async {
  final evidence = Directory('evidence');
  if (!await evidence.exists()) return;
  const needles = <String>{
    'access_token',
    'refresh_token',
    'authorization:',
    'bearer ',
    'device_auth_id',
    'user_code',
    'authorization_code',
    'code_verifier',
    'nonce',
    'android_serial',
    'run-as ',
    'adb -s ',
  };
  final prohibited = <RegExp>[
    RegExp(r'(?<![A-Za-z0-9])/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+'),
    RegExp(r'\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}'),
    RegExp(r'\b[a-f0-9]{64}\b', caseSensitive: false),
    RegExp(r'\b(?:[A-F0-9]{2}:){5}[A-F0-9]{2}\b', caseSensitive: false),
  ];
  var invalid = false;
  await for (final entity in evidence.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final source = await entity.readAsString();
    final lower = source.toLowerCase();
    // The renderer deliberately publishes these three immutable provenance
    // digests.  Remove only their exact, labelled Markdown forms before the
    // generic digest scan so a token-like 64-character value elsewhere still
    // fails closed.
    final withoutProvenance = source
        .replaceAllMapped(
          RegExp(r'^- Package commit: `[a-f0-9]{40}`$', multiLine: true),
          (_) => '',
        )
        .replaceAllMapped(
          RegExp(r'^- Evidence APK SHA-256: `[a-f0-9]{64}`$', multiLine: true),
          (_) => '',
        )
        .replaceAllMapped(
          RegExp(
            r'^- Protocol source commit: `[a-f0-9]{40}`$',
            multiLine: true,
          ),
          (_) => '',
        );
    if (needles.any(lower.contains) ||
        prohibited.any((pattern) => pattern.hasMatch(withoutProvenance))) {
      invalid = true;
    }
  }
  if (invalid) {
    stderr.writeln('prohibited secret-shaped or identifying evidence content');
    exitCode = 1;
  }
}
