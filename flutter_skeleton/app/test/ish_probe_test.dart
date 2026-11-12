import 'package:flutter_test/flutter_test.dart';

import 'package:amore/core/native/ish_probe.dart';

/// On the test host (macOS) the iSH symbol is absent, so the probe must answer
/// null instead of throwing — the UI then hides the sandbox row.
void main() {
  test('probe degrades when the iSH host is not linked', () {
    expect(IshProbe.linkedMarker(), isNull);
    expect(IshProbe.isLinked, isFalse);
  });
}
