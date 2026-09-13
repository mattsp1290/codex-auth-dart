import 'dart:convert';
import 'dart:io';

const _allowedTopLevel = <String>{
  'packageCommit',
  'apkDigest',
  'flavor',
  'accountCategory',
  'clientVersion',
  'toolchain',
  'rows',
};
const _states = <String>{'pass', 'fail', 'blocked', 'not-safely-inducible'};

/// Renders finite, redacted evidence JSON into a repository Markdown note.
/// Input is deliberately restricted so server text, identifiers, and tokens
/// cannot be smuggled into the artifact.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('usage: run_ayn_thor_evidence.dart <output-directory>');
  }
  final input = jsonDecode(await stdin.transform(utf8.decoder).join());
  if (input is! Map<String, Object?> ||
      !input.keys.toSet().containsAll(_allowedTopLevel) ||
      input.keys.any((key) => !_allowedTopLevel.contains(key))) {
    throw FormatException('invalid finite evidence schema');
  }
  final commit = input['packageCommit'];
  final digest = input['apkDigest'];
  final flavor = input['flavor'];
  final account = input['accountCategory'];
  final version = input['clientVersion'];
  final rows = input['rows'];
  if (commit is! String ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) ||
      digest is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
      flavor is! String ||
      flavor != 'evidence' ||
      account is! String ||
      !<String>{
        'ChatGPT Plus',
        'ChatGPT Pro',
        'ChatGPT Business',
      }.contains(account) ||
      version is! String ||
      version != '0.154.0' ||
      rows is! List) {
    throw FormatException('invalid evidence values');
  }
  final renderedRows = <String>[];
  for (final row in rows) {
    if (row is! Map<String, Object?> ||
        row.length != 2 ||
        row['id'] is! String ||
        row['state'] is! String ||
        !_states.contains(row['state']) ||
        !RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(row['id']! as String)) {
      throw FormatException('invalid evidence row');
    }
    renderedRows.add('| ${row['id']} | ${row['state']} |');
  }
  final output = Directory(arguments.single);
  await output.create(recursive: true);
  final note = File('${output.path}/$commit.md');
  await note.writeAsString(
    <String>[
      '# AYN Thor authentication evidence',
      '',
      '- Package commit: `$commit`',
      '- Evidence APK SHA-256: `$digest`',
      '- Flavor: `$flavor`',
      '- Account category: `$account`',
      '- Catalog client version: `$version`',
      '',
      '| Row | State |',
      '| --- | --- |',
      ...renderedRows,
      '',
    ].join('\n'),
  );
}
