import 'package:flutter/services.dart';

import 'build_provenance.dart';
import 'evidence_controls.dart';

/// App-private single-use command/result exchange for the evidence variant.
/// The Android implementation is compiled only into the evidence flavor.
final class EvidenceStateStore {
  const EvidenceStateStore({
    MethodChannel? channel,
    String? expectedPackageCommit,
    String? expectedFlavor,
  }) : _channel =
           channel ?? const MethodChannel('codex_auth/evidence_state_v1'),
       _expectedPackageCommit =
           expectedPackageCommit ?? BuildProvenance.packageCommit,
       _expectedFlavor = expectedFlavor ?? BuildProvenance.flavor;

  final MethodChannel _channel;
  final String _expectedPackageCommit;
  final String _expectedFlavor;

  Future<EvidenceCommand?> consumeCommand() async {
    final raw = await _channel.invokeMethod<String>('consumeCommand');
    if (raw == null) return null;
    final command = EvidenceCommand.decode(raw);
    if (command.packageCommit != _expectedPackageCommit ||
        command.flavor != _expectedFlavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    return command;
  }

  Future<void> writeResult(EvidenceResult result) async {
    if (result.command.packageCommit != _expectedPackageCommit ||
        result.command.flavor != _expectedFlavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    final written = await _channel.invokeMethod<bool>(
      'writeResult',
      <String, Object?>{'result': result.encode()},
    );
    if (written != true) throw StateError('evidence result unavailable');
  }

  Future<EvidenceCheckpoint?> readCheckpoint() async {
    final raw = await _channel.invokeMethod<String>('readCheckpoint');
    if (raw == null) return null;
    final checkpoint = EvidenceCheckpoint.decode(raw);
    if (checkpoint.command.packageCommit != _expectedPackageCommit ||
        checkpoint.command.flavor != _expectedFlavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    return checkpoint;
  }

  Future<void> writeCheckpoint(EvidenceCheckpoint checkpoint) async {
    if (checkpoint.command.packageCommit != _expectedPackageCommit ||
        checkpoint.command.flavor != _expectedFlavor) {
      throw const FormatException('evidence provenance mismatch');
    }
    final written = await _channel.invokeMethod<bool>(
      'writeCheckpoint',
      <String, Object?>{'checkpoint': checkpoint.encode()},
    );
    if (written != true) throw StateError('evidence checkpoint unavailable');
  }

  Future<void> clearCheckpoint() async {
    if (await _channel.invokeMethod<bool>('clearCheckpoint') != true) {
      throw StateError('evidence checkpoint unavailable');
    }
  }
}
