part of 'client.dart';

/// Frozen compatibility value supplied with a catalog request.
final class CatalogQuery {
  const CatalogQuery(this.clientVersion) : assert(clientVersion.length > 0);
  final String clientVersion;
}

/// An exact account-visible model and reasoning-effort tuple.
final class ModelTuple {
  const ModelTuple(this.slug, this.effort);
  final String slug;
  final String effort;

  @override
  bool operator ==(Object other) =>
      other is ModelTuple && other.slug == slug && other.effort == effort;
  @override
  int get hashCode => Object.hash(slug, effort);
}

/// A credential-generation-bound catalog result. It cannot be constructed by consumers.
final class ModelCatalogSnapshot {
  ModelCatalogSnapshot._(
    this._tuples,
    this._generation,
    this._clientVersion,
    this._expiresAt,
  );
  final Set<ModelTuple> _tuples;
  final String _generation;
  final String _clientVersion;
  final DateTime _expiresAt;
}

/// A tuple-specific send capability. It cannot be constructed by consumers.
final class ModelAdmission {
  ModelAdmission._(
    this._tuple,
    this._generation,
    this._clientVersion,
    this._expiresAt,
  );
  final ModelTuple _tuple;
  final String _generation;
  final String _clientVersion;
  final DateTime _expiresAt;
}

/// Bounded user input for a Responses request. Model fields are deliberately absent.
final class CodexResponsesRequest {
  CodexResponsesRequest({required this.input, Map<String, Object?>? options})
    : options = Map<String, Object?>.unmodifiable(
        options ?? const <String, Object?>{},
      );
  final String input;
  final Map<String, Object?> options;
}

/// An owned stream. Call [close] when stopping early.
final class CodexResponseStream {
  CodexResponseStream(this.bytes, this.close);
  final Stream<List<int>> bytes;
  final FutureOr<void> Function() close;
}
