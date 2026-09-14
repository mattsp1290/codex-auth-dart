import 'dart:convert';
import 'dart:io';

import 'src/evidence_assembler.dart';

Future<void> main() async {
  try {
    final decoded = jsonDecode(await stdin.transform(utf8.decoder).join());
    if (decoded is! Map) throw const FormatException();
    stdout.writeln(
      jsonEncode(assembleEvidence(Map<String, Object?>.from(decoded))),
    );
  } on Object {
    stderr.writeln('finite evidence assembly rejected');
    exitCode = 1;
  }
}
