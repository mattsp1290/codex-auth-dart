import 'dart:convert';
import 'dart:io';

import 'src/protocol_contract.dart';

const _cliVersion = '0.154.0';
const _officialTag = 'rust-v0.154.0';
const _officialCommit = '6b9826e3aa83b1a5947db50f4332cb9c65f1b340';
const _officialRemote = 'https://github.com/openai/codex.git';

/// Binds the installed CLI version to its official immutable release source.
/// An optional checked-out source root enables semantic contract validation.
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      arguments.length > 2 ||
      !_isCommit(arguments.first)) {
    throw ArgumentError(
      'usage: protocol_provenance.dart <package-commit> [official-source-root]',
    );
  }
  _verifyInstalledCli();
  _verifyOfficialTag();
  Directory? temporary;
  try {
    final root = arguments.length == 2
        ? Directory(arguments[1])
        : (temporary = await _fetchOfficialCheckout());
    _verifyCheckout(root);
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'packageCommit': arguments.first,
        'cliVersion': _cliVersion,
        'sourceTag': _officialTag,
        'sourceCommit': _officialCommit,
        'catalogClientVersion': _cliVersion,
        'semanticContractVerified': true,
      }),
    );
  } finally {
    if (temporary != null && await temporary.exists()) {
      await temporary.parent.delete(recursive: true);
    }
  }
}

Future<Directory> _fetchOfficialCheckout() async {
  final temporary = await Directory.systemTemp.createTemp('codex-provenance-');
  final target = Directory('${temporary.path}${Platform.pathSeparator}source');
  final result = await Process.run('git', <String>[
    'clone',
    '--depth',
    '1',
    '--branch',
    _officialTag,
    '--single-branch',
    _officialRemote,
    target.path,
  ]);
  if (result.exitCode != 0) {
    await temporary.delete(recursive: true);
    throw StateError('official source checkout cannot be obtained');
  }
  return target;
}

void _verifyInstalledCli() {
  final result = Process.runSync('codex', <String>['--version']);
  if (result.exitCode != 0 ||
      result.stdout is! String ||
      (result.stdout as String).trim() != 'codex-cli $_cliVersion') {
    throw StateError('installed CLI does not match the frozen release');
  }
}

void _verifyOfficialTag() {
  final result = Process.runSync('git', <String>[
    'ls-remote',
    _officialRemote,
    'refs/tags/$_officialTag^{}',
  ]);
  if (result.exitCode != 0 ||
      result.stdout is! String ||
      !(result.stdout as String).startsWith(_officialCommit)) {
    throw StateError(
      'official release tag does not resolve to the frozen source',
    );
  }
}

void _verifyCheckout(Directory root) {
  final revision = Process.runSync('git', <String>[
    '-C',
    root.path,
    'rev-parse',
    'HEAD',
  ]);
  if (revision.exitCode != 0 ||
      revision.stdout is! String ||
      (revision.stdout as String).trim() != _officialCommit) {
    throw StateError(
      'official source checkout revision differs from the release',
    );
  }
  try {
    verifyProtocolContract(root);
  } on FormatException {
    throw StateError(
      'official source differs from the expected protocol contract',
    );
  }
}

bool _isCommit(String value) =>
    value.length == 40 &&
    value.codeUnits.every(
      (unit) => (unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102),
    );
