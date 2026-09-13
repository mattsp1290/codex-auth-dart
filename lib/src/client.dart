import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'cancellation.dart';
import 'credential_store.dart';
import 'credentials.dart';
import 'errors.dart';
import 'http_transport.dart';
import 'jwt_claims.dart';
import 'protocol.dart';

part 'model_catalog.dart';

/// Dependencies owned by a host. No production endpoint is configurable.
final class CodexAuthOptions {
  const CodexAuthOptions({
    required this.store,
    required this.transport,
    this._clock,
    this.lifetimeCancellation,
    this.refreshMargin = const Duration(minutes: 2),
    this.catalogTtl = const Duration(minutes: 5),
  });

  final CredentialStore store;
  final HttpTransport transport;
  final DateTime Function()? _clock;
  final CancellationSignal? lifetimeCancellation;
  final Duration refreshMargin;
  final Duration catalogTtl;
}

/// A host callback for the device authorization presentation.
typedef DevicePrompt = FutureOr<void> Function(DeviceLoginPrompt prompt);

/// Safe device authorization data. It contains no device or authorization token.
final class DeviceLoginPrompt {
  const DeviceLoginPrompt({
    required this.verificationUri,
    required this.userCode,
    required this.expiresAt,
  });
  final Uri verificationUri;
  final String userCode;
  final DateTime expiresAt;
}

/// Pure-Dart Codex subscription authentication client.
final class CodexAuthClient {
  CodexAuthClient(CodexAuthOptions options)
    : _store = options.store,
      _transport = options.transport,
      _clock = options._clock ?? DateTime.now,
      _lifetimeCancellation = options.lifetimeCancellation,
      _refreshMargin = options.refreshMargin,
      _catalogTtl = options.catalogTtl,
      _sessionId = _newSessionId();

  final CredentialStore _store;
  final HttpTransport _transport;
  final DateTime Function() _clock;
  final CancellationSignal? _lifetimeCancellation;
  final Duration _refreshMargin;
  final Duration _catalogTtl;
  final String _sessionId;

  CancellationSignal? _signal(CancellationSignal? operation) =>
      CombinedCancellationSignal(_lifetimeCancellation, operation);

  /// Returns token-free local state, clearing malformed records fail-closed.
  Future<AuthStatus> status({CancellationSignal? cancellation}) async {
    final signal = _signal(cancellation);
    throwIfCancelled(signal);
    return _store.transaction((transaction) async {
      throwIfCancelled(signal);
      final raw = await transaction.read();
      if (raw == null) return AuthStatus.signedOut;
      if (decodeCredentials(raw) == null) {
        await transaction.clear();
        return AuthStatus.reauthenticationRequired;
      }
      return AuthStatus.signedIn;
    });
  }

  /// Clears local credentials only; it does not attempt remote revocation.
  Future<void> logoutLocal({CancellationSignal? cancellation}) async {
    final signal = _signal(cancellation);
    throwIfCancelled(signal);
    await _store.transaction((transaction) async {
      throwIfCancelled(signal);
      await transaction.clear();
    });
  }

  /// Performs device-code login and reports success only after a durable write.
  Future<void> loginDevice({
    required DevicePrompt onPrompt,
    CancellationSignal? cancellation,
  }) async {
    final signal = _signal(cancellation);
    throwIfCancelled(signal);
    final start = await _transport.send(
      HttpRequestData(
        method: 'POST',
        uri: protocolUri(authOrigin, deviceAuthorizePath),
        headers: const {
          'content-type': 'application/json',
          'accept': 'application/json',
        },
        body: utf8Body(
          jsonEncode(<String, String>{'client_id': codexClientId}),
        ),
      ),
      cancellation: signal,
    );
    _rejectRedirect(start, 'deviceLogin');
    final started = await _boundedJson(start, 'deviceLogin');
    final deviceAuthId = started['device_auth_id'];
    final userCode = started['user_code'];
    final interval = started['interval'];
    final intervalSeconds = interval is num
        ? interval.toInt()
        : interval is String
        ? int.tryParse(interval.trim())
        : null;
    if (start.statusCode != 200 ||
        deviceAuthId is! String ||
        deviceAuthId.isEmpty ||
        userCode is! String ||
        !RegExp(r'^[A-Za-z0-9-]{4,64}$').hasMatch(userCode) ||
        intervalSeconds == null ||
        intervalSeconds < 1) {
      throw const CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: 'deviceLogin',
      );
    }
    final uri = protocolUri(authOrigin, deviceVerificationPath);
    final expiry = _clock().toUtc().add(deviceAuthorizationCap);
    await onPrompt(
      DeviceLoginPrompt(
        verificationUri: uri,
        userCode: userCode,
        expiresAt: expiry,
      ),
    );
    while (_clock().toUtc().isBefore(expiry)) {
      throwIfCancelled(signal);
      await _delay(Duration(seconds: intervalSeconds.clamp(1, 30)), signal);
      final poll = await _transport.send(
        HttpRequestData(
          method: 'POST',
          uri: protocolUri(authOrigin, deviceTokenPath),
          headers: const {
            'content-type': 'application/json',
            'accept': 'application/json',
          },
          body: utf8Body(
            jsonEncode(<String, String>{
              'device_auth_id': deviceAuthId,
              'user_code': userCode,
            }),
          ),
        ),
        cancellation: signal,
      );
      _rejectRedirect(poll, 'deviceLogin');
      if (poll.statusCode == 403 || poll.statusCode == 404) {
        await poll.body.drain<void>();
        continue;
      }
      final payload = await _boundedJson(poll, 'deviceLogin');
      final authorizationCode = payload['authorization_code'];
      final codeVerifier = payload['code_verifier'];
      final codeChallenge = payload['code_challenge'];
      if (poll.statusCode == 200 &&
          authorizationCode is String &&
          authorizationCode.isNotEmpty &&
          codeVerifier is String &&
          codeVerifier.isNotEmpty &&
          codeChallenge is String &&
          codeChallenge.isNotEmpty) {
        await _exchangeAndPersist(authorizationCode, codeVerifier, signal);
        return;
      }
      throw const CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: 'deviceLogin',
      );
    }
    throw const CodexAuthException(
      CodexAuthErrorCategory.deviceAuthorizationExpired,
      operation: 'deviceLogin',
    );
  }

  /// Fetches exactly one current account catalog using the frozen compatibility value.
  Future<ModelCatalogSnapshot> listModels(
    CatalogQuery query, {
    CancellationSignal? cancellation,
  }) async {
    if (query.clientVersion != frozenCatalogClientVersion) {
      throw const CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: 'listModels',
      );
    }
    final signal = _signal(cancellation);
    return _withFreshCredentials('listModels', signal, (
      credentials,
      transaction,
    ) async {
      final response = await _transport.send(
        HttpRequestData(
          method: 'GET',
          uri: protocolUri(apiOrigin, catalogPath, {
            'client_version': query.clientVersion,
          }),
          headers: _authHeaders(credentials),
        ),
        cancellation: signal,
      );
      _rejectRedirect(response, 'listModels');
      if (response.statusCode == 401 || response.statusCode == 403) {
        await transaction.clear();
        throw const CodexAuthException(
          CodexAuthErrorCategory.reauthenticationRequired,
          operation: 'listModels',
          requiresReauthentication: true,
        );
      }
      final payload = await _boundedJson(response, 'listModels');
      if (response.statusCode != 200) {
        throw _safeResponseError(response.statusCode, 'listModels');
      }
      final entries = payload['models'];
      if (entries is! List || entries.length > 1000) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.protocolFailure,
          operation: 'listModels',
        );
      }
      final tuples = <ModelTuple>{};
      for (final entry in entries) {
        if (entry is! Map) continue;
        final slug = entry['slug'];
        final efforts = entry['supported_reasoning_levels'];
        final visibility = entry['visibility'];
        final inApi = entry['supported_in_api'];
        if (slug is! String ||
            efforts is! List ||
            visibility != 'list' ||
            inApi != true) {
          continue;
        }
        for (final effort in efforts) {
          if (effort is Map && effort['effort'] is String) {
            tuples.add(ModelTuple(slug, effort['effort']! as String));
          }
        }
      }
      return ModelCatalogSnapshot._(
        tuples,
        credentials.generation,
        query.clientVersion,
        _clock().toUtc().add(_catalogTtl),
      );
    });
  }

  /// Locally admits one exact tuple without another catalog request.
  Future<ModelAdmission> admitModel(
    ModelCatalogSnapshot snapshot,
    String slug,
    String effort, {
    CancellationSignal? cancellation,
  }) async {
    final signal = _signal(cancellation);
    throwIfCancelled(signal);
    return _store.transaction((transaction) async {
      final credentials = await _readValid(transaction, 'admitModel');
      if (credentials == null ||
          snapshot._generation != credentials.generation ||
          snapshot._clientVersion != frozenCatalogClientVersion ||
          _clock().toUtc().isAfter(snapshot._expiresAt)) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.staleAdmission,
          operation: 'admitModel',
        );
      }
      final tuple = ModelTuple(slug, effort);
      if (!snapshot._tuples.any((candidate) => candidate.slug == slug)) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.modelUnavailable,
          operation: 'admitModel',
        );
      }
      if (!snapshot._tuples.contains(tuple)) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.effortUnavailable,
          operation: 'admitModel',
        );
      }
      return ModelAdmission._(
        tuple,
        snapshot._generation,
        snapshot._clientVersion,
        snapshot._expiresAt,
      );
    });
  }

  /// Sends an admitted request. Model and effort are constructed internally.
  Future<CodexResponseStream> sendResponses(
    ModelAdmission admission,
    CodexResponsesRequest request, {
    CancellationSignal? cancellation,
  }) async {
    if (request.input.isEmpty ||
        request.input.length > 32768 ||
        request.options.containsKey('model') ||
        request.options.containsKey('reasoning')) {
      throw const CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: 'sendResponses',
      );
    }
    final signal = _signal(cancellation);
    return _withFreshCredentials('sendResponses', signal, (
      credentials,
      transaction,
    ) async {
      if (admission._generation != credentials.generation ||
          admission._clientVersion != frozenCatalogClientVersion ||
          _clock().toUtc().isAfter(admission._expiresAt)) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.staleAdmission,
          operation: 'sendResponses',
        );
      }
      final body = <String, Object?>{
        ...request.options,
        'instructions': '',
        'input': <Object?>[
          <String, Object?>{
            'type': 'message',
            'role': 'user',
            'content': <Object?>[
              <String, String>{'type': 'input_text', 'text': request.input},
            ],
          },
        ],
        'tools': <Object?>[],
        'tool_choice': 'auto',
        'parallel_tool_calls': false,
        'model': admission._tuple.slug,
        'reasoning': <String, String>{'effort': admission._tuple.effort},
        'store': false,
        'stream': true,
        'include': <String>['reasoning.encrypted_content'],
      };
      final response = await _transport.send(
        HttpRequestData(
          method: 'POST',
          uri: protocolUri(apiOrigin, responsesPath),
          headers: <String, String>{
            ..._authHeaders(credentials),
            'content-type': 'application/json',
            'accept': 'text/event-stream',
          },
          body: utf8Body(jsonEncode(body)),
        ),
        cancellation: signal,
      );
      _rejectRedirect(response, 'sendResponses');
      if (response.statusCode == 401 || response.statusCode == 403) {
        await transaction.clear();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.close?.call();
        throw _safeResponseError(response.statusCode, 'sendResponses');
      }
      return CodexResponseStream(
        response.body,
        () async => response.close?.call(),
      );
    });
  }

  Future<T> _withFreshCredentials<T>(
    String operation,
    CancellationSignal? signal,
    Future<T> Function(
      Credentials credentials,
      CredentialTransaction transaction,
    )
    action,
  ) async {
    throwIfCancelled(signal);
    return _store.transaction((transaction) async {
      var credentials = await _readValid(transaction, operation);
      if (credentials == null) {
        throw const CodexAuthException(
          CodexAuthErrorCategory.reauthenticationRequired,
          operation: 'credentials',
          requiresReauthentication: true,
        );
      }
      if (!_clock().toUtc().isBefore(
        credentials.expiresAt.subtract(_refreshMargin),
      )) {
        credentials = await _refresh(
          transaction,
          credentials,
          signal,
          operation,
        );
      }
      throwIfCancelled(signal);
      return action(credentials, transaction);
    });
  }

  Future<Credentials> _refresh(
    CredentialTransaction transaction,
    Credentials old,
    CancellationSignal? signal,
    String operation,
  ) async {
    try {
      final response = await _transport.send(
        HttpRequestData(
          method: 'POST',
          uri: protocolUri(authOrigin, tokenPath),
          headers: const {
            'content-type': 'application/x-www-form-urlencoded',
            'accept': 'application/json',
          },
          body: formBody({
            'grant_type': 'refresh_token',
            'refresh_token': old.refreshToken,
            'client_id': codexClientId,
          }),
        ),
        cancellation: signal,
      );
      _rejectRedirect(response, operation);
      final payload = await _boundedJson(response, operation);
      if (payload['error'] == 'invalid_grant') {
        await transaction.clear();
        throw const CodexAuthException(
          CodexAuthErrorCategory.reauthenticationRequired,
          operation: 'refresh',
          requiresReauthentication: true,
        );
      }
      final next = _credentialsFromTokenPayload(
        payload,
        old.generation,
        old.accountId,
        false,
      );
      if (next == null || response.statusCode != 200) {
        await transaction.clear();
        throw const CodexAuthException(
          CodexAuthErrorCategory.reauthenticationRequired,
          operation: 'refresh',
          requiresReauthentication: true,
        );
      }
      await transaction.replace(encodeCredentials(next));
      return next;
    } on CodexAuthException {
      rethrow;
    } on Object {
      // Refresh dispatch is ambiguous once transport may have started: fail closed.
      await transaction.clear();
      throw const CodexAuthException(
        CodexAuthErrorCategory.reauthenticationRequired,
        operation: 'refresh',
        requiresReauthentication: true,
      );
    }
  }

  Future<void> _exchangeAndPersist(
    String authorizationCode,
    String codeVerifier,
    CancellationSignal? signal,
  ) async {
    final response = await _transport.send(
      HttpRequestData(
        method: 'POST',
        uri: protocolUri(authOrigin, tokenPath),
        headers: const {
          'content-type': 'application/x-www-form-urlencoded',
          'accept': 'application/json',
        },
        body: formBody({
          'grant_type': 'authorization_code',
          'code': authorizationCode,
          'client_id': codexClientId,
          'redirect_uri': deviceRedirectUri,
          'code_verifier': codeVerifier,
        }),
      ),
      cancellation: signal,
    );
    _rejectRedirect(response, 'loginDevice');
    final credentials = _credentialsFromTokenPayload(
      await _boundedJson(response, 'loginDevice'),
      newCredentialGeneration(),
      null,
      true,
    );
    if (credentials == null || response.statusCode != 200) {
      throw const CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: 'loginDevice',
      );
    }
    await _store.transaction(
      (transaction) => transaction.replace(encodeCredentials(credentials)),
    );
  }

  Future<Credentials?> _readValid(
    CredentialTransaction transaction,
    String operation,
  ) async {
    final raw = await transaction.read();
    if (raw == null) return null;
    final credentials = decodeCredentials(raw);
    if (credentials == null) {
      await transaction.clear();
      throw CodexAuthException(
        CodexAuthErrorCategory.reauthenticationRequired,
        operation: operation,
        requiresReauthentication: true,
      );
    }
    return credentials;
  }

  Credentials? _credentialsFromTokenPayload(
    Map<String, Object?> payload,
    String generation,
    String? oldAccount,
    bool requireIdentity,
  ) {
    final access = payload['access_token'];
    final refresh = payload['refresh_token'];
    final expires = payload['expires_in'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty ||
        (expires is! num && expirationFromAccessToken(access) == null) ||
        (expires is num && expires <= 0)) {
      return null;
    }
    final expiresAt = expires is num
        ? _clock().toUtc().add(Duration(seconds: expires.toInt()))
        : expirationFromAccessToken(access)!;
    if (!expiresAt.isAfter(_clock().toUtc())) return null;
    final idToken = payload['id_token'];
    final accountFromIdToken = idToken is String
        ? chatGptAccountIdFromIdToken(idToken)
        : null;
    // The pinned exchange response contains an id_token carrying this claim.
    // Its refresh response may omit id_token; Codex itself preserves the prior
    // account binding in that case because the refresh grant is account-bound.
    final account = accountFromIdToken ?? (requireIdentity ? null : oldAccount);
    if (account == null || account.isEmpty) return null;
    if (oldAccount != null && account != oldAccount) {
      return null;
    }
    return Credentials(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
      generation: generation,
      accountId: account,
    );
  }

  Map<String, String> _authHeaders(Credentials credentials) => <String, String>{
    'authorization': 'Bearer ${credentials.accessToken}',
    'originator': codexOriginator,
    'session_id': _sessionId,
    'user-agent': 'codex-auth-dart/0.1.0 (dart)',
    'chatgpt-account-id': credentials.accountId,
  };

  static String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _rejectRedirect(HttpResponseData response, String operation) {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw CodexAuthException(
        CodexAuthErrorCategory.redirectRefused,
        operation: operation,
      );
    }
  }

  Future<Map<String, Object?>> _boundedJson(
    HttpResponseData response,
    String operation,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.body) {
      bytes.addAll(chunk);
      if (bytes.length > 1024 * 1024) {
        throw CodexAuthException(
          CodexAuthErrorCategory.protocolFailure,
          operation: operation,
        );
      }
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, Object?> ? value : <String, Object?>{};
    } on Object {
      throw CodexAuthException(
        CodexAuthErrorCategory.protocolFailure,
        operation: operation,
      );
    }
  }

  CodexAuthException _safeResponseError(int status, String operation) =>
      CodexAuthException(
        status == 429
            ? CodexAuthErrorCategory.quotaExceeded
            : CodexAuthErrorCategory.requestFailed,
        operation: operation,
        canRetry: status >= 500 || status == 429,
      );

  Future<void> _delay(Duration duration, CancellationSignal? signal) async {
    final timer = Future<void>.delayed(duration);
    if (signal == null) return timer;
    await Future.any(<Future<void>>[timer, signal.whenCancelled]);
    throwIfCancelled(signal);
  }
}
