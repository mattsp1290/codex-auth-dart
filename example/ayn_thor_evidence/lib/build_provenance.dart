/// Compile-time provenance embedded by the evidence build command.
final class BuildProvenance {
  const BuildProvenance._();

  static const packageCommit = String.fromEnvironment(
    'PACKAGE_COMMIT',
    defaultValue: 'unfrozen',
  );
  static const flavor = String.fromEnvironment(
    'EVIDENCE_FLAVOR',
    defaultValue: 'ordinary',
  );
}
