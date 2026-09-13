import 'dart:io';

/// Refuses likely credential-bearing artifacts without echoing a matched value.
Future<void> main() async {
  const prohibited = <String>[
    'access_token',
    'refresh_token',
    'authorization: bearer',
  ];
  final files = await Process.run('git', <String>['ls-files']);
  if (files.exitCode != 0) exitCode = 1;
  for (final path
      in (files.stdout as String)
          .split('\n')
          .where((line) => line.isNotEmpty)) {
    // Protocol fixtures legitimately name OAuth fields in order to test their
    // encoding. Evidence artifacts must never carry either field names or
    // values, so that is the release-facing scan boundary.
    if (!path.startsWith('evidence/')) continue;
    final text = await File(path).readAsString();
    if (prohibited.any((needle) => text.toLowerCase().contains(needle))) {
      stderr.writeln('prohibited credential-shaped field in tracked artifact');
      exitCode = 1;
    }
  }
}
