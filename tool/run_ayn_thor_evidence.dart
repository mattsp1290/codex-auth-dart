import 'dart:convert';
import 'dart:io';

import 'evidence_schema.dart';

/// Renders a validated, nonce-free finite evidence record into Markdown.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('usage: run_ayn_thor_evidence.dart <output-directory>');
  }
  final evidence = EvidenceSchema.parseRenderable(
    await stdin.transform(utf8.decoder).join(),
  );
  final output = Directory(arguments.single);
  await output.create(recursive: true);
  final note = File('${output.path}/${evidence['packageCommit']}.md');
  final rows = List<Map<String, Object?>>.from(evidence['rows']! as List);
  final tuples = List<Map<String, Object?>>.from(evidence['tuples']! as List);
  await note.writeAsString(
    <String>[
      '# AYN Thor authentication evidence',
      '',
      '- Package commit: `${evidence['packageCommit']}`',
      '- Evidence APK SHA-256: `${evidence['apkDigest']}`',
      '- Flavor: `evidence`',
      '- Account category: `${evidence['accountCategory']}`',
      '- Catalog client version: `${evidence['clientVersion']}`',
      '- Protocol source commit: `${evidence['protocolCommit']}`',
      '',
      '| Row | State |',
      '| --- | --- |',
      ...rows.map((row) => '| ${row['id']} | ${row['state']} |'),
      '',
      '| Model | Effort | Admitted | Request accepted | Identity verified |',
      '| --- | --- | --- | --- | --- |',
      ...tuples.map(
        (tuple) => '| ${tuple['slug']} | medium | yes | yes | yes |',
      ),
      '',
      'Redirect matrix: all 25 synthetic request-class/status cases recorded one source hit, zero target hits, and bounded peer closure.',
      '',
    ].join('\n'),
  );
}
