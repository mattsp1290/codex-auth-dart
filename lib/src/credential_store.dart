/// An exclusive host-owned credential transaction.
abstract interface class CredentialTransaction {
  /// Reads the opaque versioned record, or null if absent.
  Future<String?> read();

  /// Atomically makes [record] the durable current record.
  Future<void> replace(String record);

  /// Atomically removes the current record.
  Future<void> clear();
}

/// A host-owned store with namespace-wide exclusive transactions.
///
/// Implementations must serialize all adapters for one logical namespace and
/// never expose partial records after a process restart.
abstract interface class CredentialStore {
  Future<T> transaction<T>(
    Future<T> Function(CredentialTransaction transaction) action,
  );
}

/// A safe store failure; adapters must not put stored values in its message.
final class CredentialStoreException implements Exception {
  const CredentialStoreException();

  @override
  String toString() => 'CredentialStoreException';
}
