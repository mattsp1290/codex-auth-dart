import 'src/release_artifact_verifier.dart';

/// Verifies flavor separation against compiled APK contents, not imports.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3 ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(arguments[0])) {
    throw ArgumentError(
      'usage: check_release_artifact.dart <package-commit> '
      '<ordinary-release.apk> <evidence-debug.apk>',
    );
  }
  await verifyReleaseArtifacts(arguments[0], arguments[1], arguments[2]);
}
