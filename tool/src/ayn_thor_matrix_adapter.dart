/// Rejects transport diagnostics while the app-private result is not yet
/// available. Full schema validation remains the engine's responsibility.
bool isFiniteResultCandidate(String source) {
  final trimmed = source.trim();
  return trimmed.startsWith('{') && trimmed.endsWith('}');
}
