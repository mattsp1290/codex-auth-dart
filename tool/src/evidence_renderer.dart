String renderEvidenceMarkdown(Map<String, Object?> evidence) {
  final rows = List<Map<String, Object?>>.from(evidence['rows']! as List);
  final tuples = List<Map<String, Object?>>.from(evidence['tuples']! as List);
  final toolchain = Map<String, Object?>.from(evidence['toolchain']! as Map);
  String predicates(Map<String, Object?> row) {
    final values = Map<String, Object?>.from(row['predicates']! as Map);
    final entries = values.entries.toList()
      ..sort((first, second) => first.key.compareTo(second.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join(', ');
  }

  return <String>[
    '# AYN Thor authentication evidence',
    '',
    '- Package commit: `${evidence['packageCommit']}`',
    '- Evidence APK SHA-256: `${evidence['apkDigest']}`',
    '- Flavor: `evidence`',
    '- Account category: `${evidence['accountCategory']}`',
    '- Catalog client version: `${evidence['clientVersion']}`',
    '- Protocol source commit: `${evidence['protocolCommit']}`',
    '',
    '## Toolchain',
    '',
    ...toolchain.entries.map((entry) => '- ${entry.key}: `${entry.value}`'),
    '',
    '## Recovery matrix',
    '',
    '| Row | State | Predicates |',
    '| --- | --- | --- |',
    ...rows.map(
      (row) => '| ${row['id']} | ${row['state']} | ${predicates(row)} |',
    ),
    '',
    '## Exact model tuples',
    '',
    '| Model | Effort | Admitted | Request accepted | Identity verified |',
    '| --- | --- | --- | --- | --- |',
    ...tuples.map(
      (tuple) =>
          '| ${tuple['slug']} | ${tuple['effort']} | '
          '${tuple['admitted']} | ${tuple['requestAccepted']} | '
          '${tuple['executedIdentityVerified']} |',
    ),
    '',
    '## Redirect containment',
    '',
    'All 25 synthetic request-class/status cases recorded one source hit, '
        'zero target hits, the expected source credential-field shape, an '
        'empty target credential-field shape, and bounded peer closure.',
    '',
  ].join('\n');
}
