import 'package:codex_auth/codex_auth.dart';

/// Token-free device-auth polling telemetry for the evidence UI.
final class DeviceAuthTelemetry {
  int pollCount = 0;
  int? lastStatus;
}

final class EvidenceDeviceAuthTransport implements HttpTransport {
  EvidenceDeviceAuthTransport(
    this._delegate, {
    required this.telemetry,
    required this.onChanged,
  });

  static const _deviceTokenPath = '/api/accounts/deviceauth/token';
  final HttpTransport _delegate;
  final DeviceAuthTelemetry telemetry;
  final void Function() onChanged;

  @override
  Future<HttpResponseData> send(
    HttpRequestData request, {
    CancellationSignal? cancellation,
  }) async {
    final response = await _delegate.send(request, cancellation: cancellation);
    if (request.uri.path == _deviceTokenPath) {
      telemetry.pollCount++;
      telemetry.lastStatus = response.statusCode;
      onChanged();
    }
    return response;
  }
}
