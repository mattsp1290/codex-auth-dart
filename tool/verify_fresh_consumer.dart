import 'dart:io';

const _canonicalRemote = 'https://github.com/mattsp1290/codex-auth-dart.git';

/// Resolves the immutable package commit in an isolated consumer and Pub cache.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(arguments.single)) {
    stderr.writeln('fresh consumer verification failed');
    exitCode = 1;
    return;
  }
  final commit = arguments.single;
  final root = await Directory.systemTemp.createTemp(
    'codex-auth-fresh-consumer-',
  );
  final cache = await Directory.systemTemp.createTemp('codex-auth-pub-cache-');
  var stage = 'setup';
  try {
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: codex_auth_fresh_consumer
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  codex_auth:
    git:
      url: $_canonicalRemote
      ref: $commit
''');
    await File('${root.path}/bin/main.dart').create(recursive: true);
    await File('${root.path}/bin/main.dart').writeAsString('''
import 'package:codex_auth/codex_auth.dart';

void main() {
  print(AuthStatus.signedOut);
}
''');
    final environment = <String, String>{
      ...Platform.environment,
      'PUB_CACHE': cache.path,
    };
    stage = 'resolution';
    await _run('pub', <String>['get'], root, environment);
    stage = 'analysis';
    await _run('analyze', <String>[], root, environment);
    stage = 'execution';
    await _run('run', <String>['bin/main.dart'], root, environment);
    stdout.writeln('fresh consumer verified');
  } on Object {
    stderr.writeln('fresh consumer $stage failed');
    exitCode = 1;
  } finally {
    if (await root.exists()) await root.delete(recursive: true);
    if (await cache.exists()) await cache.delete(recursive: true);
  }
}

Future<void> _run(
  String command,
  List<String> arguments,
  Directory workingDirectory,
  Map<String, String> environment,
) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    <String>[command, ...arguments],
    workingDirectory: workingDirectory.path,
    environment: environment,
  );
  if (result.exitCode != 0) throw StateError('consumer command failed');
}
