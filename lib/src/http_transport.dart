import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cancellation.dart';

/// The furthest finite point reached by a failed transport request.
enum HttpDispatchPhase { notDispatched, possiblyDispatched }

/// A redacted transport failure with no URI, headers, body, or platform text.
final class HttpTransportException implements Exception {
  const HttpTransportException(this.phase, this.outcome);

  final HttpDispatchPhase phase;
  final HttpTransportOutcome outcome;

  @override
  String toString() => 'HttpTransportException(${outcome.name}, ${phase.name})';
}

/// A finite request lifecycle outcome.
enum HttpTransportOutcome {
  connectTimeout,
  responseHeaderTimeout,
  cancelled,
  failed,
}

/// A library-constructed request. [followRedirects] is always false.
final class HttpRequestData {
  HttpRequestData({
    required this.method,
    required this.uri,
    Map<String, String>? headers,
    this.body = const <int>[],
  }) : headers = Map<String, String>.unmodifiable(
         headers ?? const <String, String>{},
       );

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int> body;
  bool get followRedirects => false;
}

/// A streaming HTTP response owned by its caller.
final class HttpResponseData {
  HttpResponseData(this.statusCode, this.headers, this.body, {this.close});

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final FutureOr<void> Function()? close;
}

/// Trusted transport boundary. It must never follow redirects.
abstract interface class HttpTransport {
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  });
}

/// The Dart IO transport. It turns off automatic redirects before dispatch.
final class DartIoHttpTransport implements HttpTransport {
  DartIoHttpTransport({
    HttpClient Function()? clientFactory,
    this.connectTimeout = const Duration(seconds: 15),
    this.responseHeaderTimeout = const Duration(seconds: 30),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Set<HttpClient> _clients = <HttpClient>{};

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    throwIfCancelled(cancellation);
    final client = _clientFactory();
    _clients.add(client);
    // ignore: close_sinks
    HttpClientRequest? ioRequest;
    try {
      ioRequest = await _awaitPhase(
        client.openUrl(request.method, request.uri),
        cancellation,
        connectTimeout,
        HttpDispatchPhase.notDispatched,
        HttpTransportOutcome.connectTimeout,
        client,
      );
      final HttpClientRequest openedRequest = ioRequest!;
      openedRequest.followRedirects = false;
      openedRequest.maxRedirects = 0;
      request.headers.forEach(openedRequest.headers.set);
      throwIfCancelled(cancellation);
      openedRequest.add(request.body);
      // The request is closed below; the response owns the resulting socket.
      // ignore: close_sinks
      final response = await _awaitPhase(
        openedRequest.close(),
        cancellation,
        responseHeaderTimeout,
        HttpDispatchPhase.possiblyDispatched,
        HttpTransportOutcome.responseHeaderTimeout,
        client,
      );
      final headers = <String, String>{};
      response.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = values.join(','),
      );
      var closed = false;
      return HttpResponseData(
        response.statusCode,
        headers,
        response,
        close: () async {
          if (closed) return;
          closed = true;
          try {
            await response
                .detachSocket()
                .then((socket) => socket.destroy())
                .catchError((_) {});
          } finally {
            _clients.remove(client);
            client.close(force: true);
          }
        },
      );
    } on OperationCancelled {
      _clients.remove(client);
      client.close(force: true);
      throw const HttpTransportException(
        HttpDispatchPhase.possiblyDispatched,
        HttpTransportOutcome.cancelled,
      );
    } on HttpTransportException {
      _clients.remove(client);
      client.close(force: true);
      rethrow;
    } on Object {
      _clients.remove(client);
      client.close(force: true);
      if (cancellation?.isCancelled ?? false) {
        throw const HttpTransportException(
          HttpDispatchPhase.possiblyDispatched,
          HttpTransportOutcome.cancelled,
        );
      }
      throw const HttpTransportException(
        HttpDispatchPhase.possiblyDispatched,
        HttpTransportOutcome.failed,
      );
    }
  }

  Future<T> _awaitPhase<T>(
    Future<T> future,
    CancellationSignal? cancellation,
    Duration timeout,
    HttpDispatchPhase phase,
    HttpTransportOutcome timeoutOutcome,
    HttpClient client,
  ) async {
    final timeoutFuture = Future<T>.delayed(timeout, () {
      client.close(force: true);
      throw HttpTransportException(phase, timeoutOutcome);
    });
    if (cancellation == null) {
      return Future.any(<Future<T>>[future, timeoutFuture]);
    }
    final cancelled = cancellation.whenCancelled.then<T>((_) {
      client.close(force: true);
      throw HttpTransportException(phase, HttpTransportOutcome.cancelled);
    });
    return Future.any(<Future<T>>[future, timeoutFuture, cancelled]);
  }

  void close({bool force = false}) {
    for (final client in _clients) {
      client.close(force: force);
    }
    _clients.clear();
  }
}

List<int> utf8Body(String body) => utf8.encode(body);
