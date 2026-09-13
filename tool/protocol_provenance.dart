import 'dart:convert';

/// Emits only immutable, non-secret protocol provenance facts.
void main(List<String> arguments) {
  const commitPattern = r'^[0-9a-f]{40}$';
  if (arguments.length != 2 ||
      !RegExp(commitPattern).hasMatch(arguments[0]) ||
      !RegExp(commitPattern).hasMatch(arguments[1])) {
    throw ArgumentError('expected two full immutable commit hashes');
  }
  print(
    jsonEncode(<String, String>{
      'goReferenceCommit': arguments[0],
      'codexSourceCommit': arguments[1],
      'catalogClientVersion': '0.154.0',
    }),
  );
}
