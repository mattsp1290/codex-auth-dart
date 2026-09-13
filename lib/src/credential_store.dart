import 'cancellation.dart';

/// An exclusive host-owned credential transaction.
abstract interface class CredentialTransaction {
  /// Whether recovery already determined that this namespace must be cleared
  /// and explicitly reauthenticated before it can be used.
  bool get requiresReauthentication;

  /// Reads the opaque versioned record, or null if absent.
  Future<String?> read();

  /// Atomically makes [record] the durable current record.
  Future<void> replace(String record);

  /// Atomically removes the current record.
  Future<void> clear();

  /// Records that a refresh may reach the authorization server.
  ///
  /// The marker must be durable before dispatch. A reconstructed store must
  /// fail closed if it finds an unresolved marker for [generation].
  Future<void> markRefreshRisk(String generation);

  /// Resolves a refresh which is proven not to have been dispatched.
  Future<void> restoreAfterNotDispatched(String generation);

  /// Atomically replaces the current record and resolves its refresh marker.
  Future<void> replaceAfterRefresh(String generation, String record);

  /// Atomically clears the current record and resolves its refresh marker.
  Future<void> clearAfterRefresh(String generation);
}

/// A host-owned store with namespace-wide exclusive transactions.
///
/// Implementations must serialize all adapters for one logical namespace and
/// never expose partial records after a process restart.
abstract interface class CredentialStore {
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action, {
    CancellationSignal? cancellation,
  });
}

/// A safe store failure; adapters must not put stored values in its message.
final class CredentialStoreException implements Exception {
  const CredentialStoreException();

  @override
  String toString() => 'CredentialStoreException';
}
