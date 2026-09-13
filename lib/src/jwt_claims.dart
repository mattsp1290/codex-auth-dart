import 'dart:convert';

/// Passively reads the one account-routing claim needed for Codex headers.
/// This is not token validation and never exposes the token or claims.
String? chatGptAccountIdFromIdToken(String token) {
  final pieces = token.split('.');
  if (pieces.length != 3 || pieces[1].isEmpty) return null;
  try {
    final payload = base64Url.normalize(pieces[1]);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
    if (decoded is! Map<String, Object?>) return null;
    final auth = decoded['https://api.openai.com/auth'];
    if (auth is! Map<String, Object?>) return null;
    final account = auth['chatgpt_account_id'];
    return account is String && account.isNotEmpty ? account : null;
  } on FormatException {
    return null;
  }
}

/// Reads an access-token expiration claim without retaining the token.
DateTime? expirationFromAccessToken(String token) {
  final pieces = token.split('.');
  if (pieces.length != 3 || pieces[1].isEmpty) return null;
  try {
    final payload = base64Url.normalize(pieces[1]);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
    if (decoded is! Map<String, Object?> || decoded['exp'] is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (decoded['exp']! as num).toInt() * 1000,
      isUtc: true,
    );
  } on FormatException {
    return null;
  }
}
