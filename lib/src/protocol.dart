import 'dart:convert';

/// Pinned production origins and private protocol constants. Not exported.
const String authOrigin = 'https://auth.openai.com';
const String apiOrigin = 'https://chatgpt.com';
const String deviceAuthorizePath = '/api/accounts/deviceauth/usercode';
const String deviceTokenPath = '/api/accounts/deviceauth/token';
const String tokenPath = '/oauth/token';
const String catalogPath = '/backend-api/codex/models';
const String responsesPath = '/backend-api/codex/responses';
const String codexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const String deviceRedirectUri = 'https://auth.openai.com/deviceauth/callback';
const String deviceVerificationPath = '/codex/device';
const Duration deviceAuthorizationCap = Duration(minutes: 15);
const String frozenCatalogClientVersion = '0.154.0';

Uri protocolUri(String origin, String path, [Map<String, String>? query]) {
  final uri = Uri.parse(origin).replace(path: path, queryParameters: query);
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw StateError('invalid fixed protocol destination');
  }
  return uri;
}

List<int> formBody(Map<String, String> values) => utf8.encode(
  values.entries
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&'),
);
