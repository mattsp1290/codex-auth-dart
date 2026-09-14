import 'package:codex_auth/codex_auth.dart';

/// Token-free device-auth polling telemetry for the evidence UI.
final class DeviceAuthTelemetry {
  int attemptsStarted = 0;
  int attemptsCompleted = 0;
  bool inFlight = false;
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
    final isPoll = request.uri.path == _deviceTokenPath;
    if (isPoll) {
      telemetry.attemptsStarted++;
      telemetry.inFlight = true;
      onChanged();
    }
    try {
      final response = await _delegate.send(
        request,
        cancellation: cancellation,
      );
      if (isPoll) {
        telemetry.attemptsCompleted++;
        telemetry.lastStatus = response.statusCode;
      }
      return response;
    } finally {
      if (isPoll) {
        telemetry.inFlight = false;
        onChanged();
      }
    }
  }
}
