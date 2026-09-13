import 'package:codex_auth/codex_auth.dart';
import 'package:test/test.dart';

void main() {
  test('public package exports token-free state and cancellation', () {
    final controller = CancellationController();
    expect(controller.isCancelled, isFalse);
    controller.cancel();
    expect(controller.isCancelled, isTrue);
    expect(AuthStatus.values, contains(AuthStatus.signedOut));
  });
}
