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
  streamIdleTimeout,
  overallTimeout,
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
    this.streamIdleTimeout = const Duration(seconds: 30),
    this.overallTimeout = const Duration(minutes: 2),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration connectTimeout;
  final Duration responseHeaderTimeout;
  final Duration streamIdleTimeout;
  final Duration overallTimeout;
  final Set<HttpClient> _clients = <HttpClient>{};

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw const HttpTransportException(
        HttpDispatchPhase.notDispatched,
        HttpTransportOutcome.cancelled,
      );
    }
    final deadline = DateTime.now().add(overallTimeout);
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
        deadline,
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
        deadline,
      );
      final headers = <String, String>{};
      response.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = values.join(','),
      );
      var closed = false;
      Future<void> closeOwned() async {
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
      }

      return HttpResponseData(
        response.statusCode,
        headers,
        _boundedBody(response, deadline, closeOwned, cancellation),
        close: closeOwned,
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
    DateTime overallDeadline,
  ) async {
    final completer = Completer<T>();
    void fail(HttpTransportOutcome outcome) {
      if (completer.isCompleted) return;
      client.close(force: true);
      completer.completeError(HttpTransportException(phase, outcome));
    }

    final phaseTimer = Timer(timeout, () => fail(timeoutOutcome));
    final remaining = overallDeadline.difference(DateTime.now());
    final overallTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => fail(HttpTransportOutcome.overallTimeout),
    );
    unawaited(
      future.then<void>(
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );
    if (cancellation != null) {
      unawaited(
        cancellation.whenCancelled.then<void>(
          (_) => fail(HttpTransportOutcome.cancelled),
        ),
      );
    }
    try {
      return await completer.future;
    } finally {
      phaseTimer.cancel();
      overallTimer.cancel();
    }
  }

  Stream<List<int>> _boundedBody(
    Stream<List<int>> source,
    DateTime overallDeadline,
    Future<void> Function() closeOwned,
    CancellationSignal? cancellation,
  ) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    Timer? overallTimer;
    var terminal = false;

    void cancelTimers() {
      idleTimer?.cancel();
      overallTimer?.cancel();
    }

    void fail(HttpTransportOutcome outcome) {
      if (terminal) return;
      terminal = true;
      cancelTimers();
      unawaited(subscription?.cancel());
      unawaited(closeOwned());
      controller.addError(
        HttpTransportException(HttpDispatchPhase.possiblyDispatched, outcome),
      );
      unawaited(controller.close());
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(
        streamIdleTimeout,
        () => fail(HttpTransportOutcome.streamIdleTimeout),
      );
    }

    controller = StreamController<List<int>>(
      onListen: () {
        resetIdleTimer();
        final remaining = overallDeadline.difference(DateTime.now());
        overallTimer = Timer(
          remaining.isNegative ? Duration.zero : remaining,
          () => fail(HttpTransportOutcome.overallTimeout),
        );
        subscription = source.listen(
          (data) {
            if (terminal) return;
            resetIdleTimer();
            controller.add(data);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (terminal) return;
            terminal = true;
            cancelTimers();
            controller.addError(error, stackTrace);
            unawaited(controller.close());
          },
          onDone: () {
            if (terminal) return;
            terminal = true;
            cancelTimers();
            unawaited(closeOwned());
            unawaited(controller.close());
          },
        );
        if (cancellation != null) {
          unawaited(
            cancellation.whenCancelled.then<void>(
              (_) => fail(HttpTransportOutcome.cancelled),
            ),
          );
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        terminal = true;
        cancelTimers();
        await subscription?.cancel();
        await closeOwned();
      },
    );
    return controller.stream;
  }

  void close({bool force = false}) {
    for (final client in _clients) {
      client.close(force: force);
    }
    _clients.clear();
  }
}

List<int> utf8Body(String body) => utf8.encode(body);
