import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cancellation.dart';

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
  DartIoHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    throwIfCancelled(cancellation);
    HttpClientRequest? ioRequest;
    StreamSubscription<void>? cancellationSubscription;
    try {
      ioRequest = await _client.openUrl(request.method, request.uri);
      ioRequest.followRedirects = false;
      ioRequest.maxRedirects = 0;
      request.headers.forEach(ioRequest.headers.set);
      cancellationSubscription = cancellation?.whenCancelled.asStream().listen((
        _,
      ) {
        ioRequest?.abort(OperationCancelled());
      });
      throwIfCancelled(cancellation);
      ioRequest.add(request.body);
      final response = await ioRequest.close();
      final headers = <String, String>{};
      response.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = values.join(','),
      );
      return HttpResponseData(
        response.statusCode,
        headers,
        response,
        close: () async {
          await cancellationSubscription?.cancel();
          await response
              .detachSocket()
              .then((socket) => socket.destroy())
              .catchError((_) {});
        },
      );
    } on OperationCancelled {
      rethrow;
    } on Object {
      if (cancellation?.isCancelled ?? false) throw OperationCancelled();
      rethrow;
    }
  }

  void close({bool force = false}) => _client.close(force: force);
}

List<int> utf8Body(String body) => utf8.encode(body);
