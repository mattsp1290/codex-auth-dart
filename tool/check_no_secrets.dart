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
    if (!path.startsWith('evidence/') && !path.startsWith('test/')) continue;
    final text = await File(path).readAsString();
    if (prohibited.any((needle) => text.toLowerCase().contains(needle))) {
      stderr.writeln('prohibited credential-shaped field in tracked artifact');
      exitCode = 1;
    }
  }
}
