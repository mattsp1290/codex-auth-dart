import 'dart:convert';
import 'dart:math';

/// Token-free authentication state.
enum AuthStatus { signedOut, signedIn, reauthenticationRequired }

final class Credentials {
  const Credentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.generation,
    required this.accountId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String generation;
  final String accountId;

  Credentials copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? accountId,
  }) => Credentials(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    generation: generation,
    accountId: accountId ?? this.accountId,
  );
}

String newCredentialGeneration() {
  final random = Random.secure();
  return List<String>.generate(
    32,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}

String encodeCredentials(Credentials credentials) =>
    jsonEncode(<String, Object?>{
      'v': 1,
      'access': credentials.accessToken,
      'refresh': credentials.refreshToken,
      'expiresAt': credentials.expiresAt.toUtc().toIso8601String(),
      'generation': credentials.generation,
      'account': credentials.accountId,
    });

Credentials? decodeCredentials(String raw) {
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?> || decoded['v'] != 1) return null;
    final access = decoded['access'];
    final refresh = decoded['refresh'];
    final expires = decoded['expiresAt'];
    final generation = decoded['generation'];
    final account = decoded['account'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty ||
        expires is! String ||
        generation is! String ||
        generation.length < 16 ||
        account is! String ||
        account.isEmpty) {
      return null;
    }
    final expiresAt = DateTime.tryParse(expires)?.toUtc();
    if (expiresAt == null) return null;
    return Credentials(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      generation: generation,
      accountId: account,
    );
  } on FormatException {
    return null;
  }
}
