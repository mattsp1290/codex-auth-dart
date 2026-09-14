import 'dart:io';

final class ProtocolRequirement {
  const ProtocolRequirement(this.id, this.relativePath, this.needle);

  final String id;
  final String relativePath;
  final String needle;
}

/// Frozen, independently testable assumptions extracted from the official
/// Codex source release used by this package.
const protocolRequirements = <ProtocolRequirement>[
  ProtocolRequirement(
    'device-user-code-path',
    'codex-rs/login/src/device_code_auth.rs',
    'format!("{auth_base_url}/deviceauth/usercode")',
  ),
  ProtocolRequirement(
    'device-token-path',
    'codex-rs/login/src/device_code_auth.rs',
    'format!("{auth_base_url}/deviceauth/token")',
  ),
  ProtocolRequirement(
    'device-fields',
    'codex-rs/login/src/device_code_auth.rs',
    'device_auth_id: uc.device_auth_id',
  ),
  ProtocolRequirement(
    'user-code-field',
    'codex-rs/login/src/device_code_auth.rs',
    'user_code: uc.user_code',
  ),
  ProtocolRequirement(
    'pkce-verifier',
    'codex-rs/login/src/device_code_auth.rs',
    'code_verifier: code_resp.code_verifier',
  ),
  ProtocolRequirement(
    'authorization-code',
    'codex-rs/login/src/device_code_auth.rs',
    '&code_resp.authorization_code',
  ),
  ProtocolRequirement(
    'device-deadline',
    'codex-rs/login/src/device_code_auth.rs',
    'Duration::from_secs(15 * 60)',
  ),
  ProtocolRequirement(
    'device-redirect',
    'codex-rs/login/src/device_code_auth.rs',
    'format!("{base_url}/deviceauth/callback")',
  ),
  ProtocolRequirement(
    'oauth-client',
    'codex-rs/login/src/auth/manager.rs',
    'pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";',
  ),
  ProtocolRequirement(
    'refresh-grant',
    'codex-rs/login/src/auth/manager.rs',
    'grant_type: "refresh_token"',
  ),
  ProtocolRequirement(
    'optional-refresh-token',
    'codex-rs/login/src/auth/manager.rs',
    'refresh_token: Option<String>',
  ),
  ProtocolRequirement(
    'invalid-grant-terminal',
    'codex-rs/login/src/auth/manager.rs',
    'eq_ignore_ascii_case("invalid_grant")',
  ),
  ProtocolRequirement(
    'account-header',
    'codex-rs/login/src/auth/manager.rs',
    '.get("chatgpt-account-id")',
  ),
  ProtocolRequirement(
    'catalog-path',
    'codex-rs/codex-api/src/endpoint/models.rs',
    '"models"',
  ),
  ProtocolRequirement(
    'catalog-client-version',
    'codex-rs/codex-api/src/endpoint/models.rs',
    'client_version={client_version}',
  ),
  ProtocolRequirement(
    'catalog-method',
    'codex-rs/codex-api/src/endpoint/models.rs',
    'provider.build_request(Method::GET, Self::path())',
  ),
  ProtocolRequirement(
    'responses-path',
    'codex-rs/codex-api/src/endpoint/responses.rs',
    'Self::Responses => "/responses"',
  ),
  ProtocolRequirement(
    'responses-method',
    'codex-rs/codex-api/src/endpoint/responses.rs',
    'Method::POST',
  ),
  ProtocolRequirement(
    'responses-stream',
    'codex-rs/codex-api/src/endpoint/responses.rs',
    'spawn_response_stream',
  ),
];

void verifyProtocolContract(Directory root) {
  final cache = <String, String>{};
  for (final requirement in protocolRequirements) {
    final source = cache.putIfAbsent(requirement.relativePath, () {
      final file = File(
        '${root.path}${Platform.pathSeparator}'
        '${requirement.relativePath}',
      );
      if (!file.existsSync()) {
        throw const FormatException('official protocol layout unavailable');
      }
      return file.readAsStringSync();
    });
    if (!source.contains(requirement.needle)) {
      throw const FormatException('official protocol contract drift');
    }
  }
}
