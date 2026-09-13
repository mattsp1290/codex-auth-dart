import 'dart:io';

/// Fails if the ordinary Flutter entrypoint imports evidence-only controls.
Future<void> main(List<String> arguments) async {
  final root = Directory(
    arguments.isEmpty ? 'example/ayn_thor_evidence/lib' : arguments.single,
  );
  final ordinary = File('${root.path}/main.dart');
  if (!await ordinary.exists()) throw StateError('ordinary entrypoint missing');
  final queued = <File>[ordinary];
  final visited = <String>{};
  const forbidden = <String>{'main_evidence.dart', 'evidence_controls.dart'};
  while (queued.isNotEmpty) {
    final file = queued.removeLast();
    if (!visited.add(file.absolute.path)) continue;
    final source = await file.readAsString();
    for (final match in RegExp(
      r"import '([^']+)'",
      multiLine: true,
    ).allMatches(source)) {
      final imported = match.group(1)!;
      if (forbidden.contains(imported)) {
        throw StateError('ordinary release graph contains evidence-only code');
      }
      if (!imported.startsWith('package:') && !imported.startsWith('dart:')) {
        queued.add(File('${file.parent.path}/$imported'));
      }
    }
  }
}
