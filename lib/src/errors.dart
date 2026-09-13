/// Safe, finite categories exposed by this package.
enum CodexAuthErrorCategory {
  cancelled,
  reauthenticationRequired,
  localCleanupRequired,
  deviceAuthorizationDeclined,
  deviceAuthorizationExpired,
  protocolFailure,
  redirectRefused,
  modelUnavailable,
  effortUnavailable,
  staleAdmission,
  planNotIncluded,
  quotaExceeded,
  requestFailed,
}

/// A redacted public error. It never carries server text, credentials, or URLs.
final class CodexAuthException implements Exception {
  const CodexAuthException(
    this.category, {
    required this.operation,
    this.canRetry = false,
    this.requiresReauthentication = false,
    this.cleanupRequired = false,
  });

  final CodexAuthErrorCategory category;
  final String operation;
  final bool canRetry;
  final bool requiresReauthentication;

  /// Local state could not be safely cleared; protected I/O is forbidden.
  final bool cleanupRequired;

  @override
  String toString() => 'CodexAuthException(${category.name}, $operation)';
}
