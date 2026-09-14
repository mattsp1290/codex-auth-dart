import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/protocol_contract.dart';

void main() {
  test('the frozen protocol fixture satisfies every named assumption', () {
    verifyProtocolContract(Directory('test/fixtures/protocol'));
  });

  for (final requirement in protocolRequirements) {
    test('${requirement.id} drift fails closed independently', () {
      final sourceRoot = Directory('test/fixtures/protocol');
      final temporary = Directory.systemTemp.createTempSync(
        'protocol-contract-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      for (final path
          in protocolRequirements.map((item) => item.relativePath).toSet()) {
        final source = File('${sourceRoot.path}/$path').readAsStringSync();
        final target = File('${temporary.path}/$path')
          ..createSync(recursive: true);
        target.writeAsStringSync(
          path == requirement.relativePath
              ? source.replaceFirst(requirement.needle, '')
              : source,
        );
      }

      expect(() => verifyProtocolContract(temporary), throwsFormatException);
    });
  }
}
