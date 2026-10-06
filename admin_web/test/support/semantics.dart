import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every label in the semantics tree under [finder], as a screen reader would
/// read them out in order.
///
/// Walked rather than matched with `find.bySemanticsLabel`, which reads
/// `RenderObject.debugSemantics` and so depends on when the semantics tree
/// happened to be built. What a screen reader is given is the thing under test
/// here -- the review queue's status chip has no text of its own, so the only
/// way to know a column heading reaches a screen reader alongside its value is
/// to read the tree.
///
/// A whole record card can come back as one merged node holding every heading
/// and value, which is what a screen reader actually announces for it, so
/// [announcedLabelContaining] is usually the more convenient of the two.
///
/// Requires semantics to be enabled; pass `tester.ensureSemantics()`'s handle to
/// `addTearDown` for the duration.
List<String> announcedLabels(WidgetTester tester, Finder finder) {
  final node = tester.getSemantics(finder);
  final labels = <String>[];
  _collect(node, labels);
  return labels;
}

void _collect(SemanticsNode node, List<String> into) {
  final label = node.getSemanticsData().label;
  if (label.isNotEmpty) into.add(label);
  node.visitChildren((child) {
    _collect(child, into);
    // `true` continues to the next sibling; `false` would stop the walk.
    return true;
  });
}

/// The single announced label containing [fragment].
///
/// Matching on a fragment rather than an exact string so a test can pin the
/// pairing ("Status, pending") without also pinning the separator.
String? announcedLabelContaining(
  WidgetTester tester,
  Finder finder,
  String fragment,
) {
  for (final label in announcedLabels(tester, finder)) {
    if (label.contains(fragment)) return label;
  }
  return null;
}
