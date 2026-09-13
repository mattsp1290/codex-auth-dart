import 'package:flutter/services.dart';

import 'build_provenance.dart';
import 'evidence_controls.dart';

/// App-private single-use command/result exchange for the evidence variant.
/// The Android implementation is compiled only into the evidence flavor.
final class EvidenceStateStore {
  const EvidenceStateStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('codex_auth/evidence_state_v1');

  final MethodChannel _channel;

  Future<EvidenceCommand?> consumeCommand() async {
    final raw = await _channel.invokeMethod<String>('consumeCommand');
    if (raw == null) return null;
    final command = EvidenceCommand.decode(raw);
    if (command.packageCommit != BuildProvenance.packageCommit ||
        command.flavor != BuildProvenance.flavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    return command;
  }

  Future<void> writeResult(EvidenceResult result) async {
    if (result.command.packageCommit != BuildProvenance.packageCommit ||
        result.command.flavor != BuildProvenance.flavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    final written = await _channel.invokeMethod<bool>(
      'writeResult',
      <String, Object?>{'result': result.encode()},
    );
    if (written != true) throw StateError('evidence result unavailable');
  }
}
