/// Reads a decimal the API sends as a JSON string.
///
/// `Decimal` is serialised as `"4.10"`, not `4.1`, and that is deliberate on
/// the server: a JSON number becomes a double on this side, and a double cannot
/// represent every `numeric(6,2)` value, so a value would be silently rounded
/// on its way to a client that was going to display it only. A number is still
/// accepted, because the same read is used on a field that is *not* a
/// `Decimal` (`score` is a real JSON number) and because a client that broke on
/// a numeric would turn a forward-compatible server change into a dead screen.
///
/// Null stays null rather than becoming a zero, and a string that will not
/// parse is read as absent rather than refused: the displayed number is not
/// worth failing a rail over, and an unreadable one is already better shown as
/// "No ratings yet" than as a `FormatException`. A value that is neither a
/// string nor a number *is* a `FormatException`, because that is a shape the
/// API documents and does not produce.
double? readDecimal(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  throw const FormatException('expected a decimal the API sends as a string');
}

/// [readDecimal] for a field the API documents as non-nullable.
///
/// Casting the wire value to `num` here is what broke tutor registration: the
/// API sends `grade_points` as a string, the cast raised a `TypeError`, and the
/// repository reported the type error rather than the unread body, so the
/// grades list never loaded and no tutor could be registered at all.
///
/// Reading it through [readDecimal] turns the same situation into a
/// `FormatException`, which the repositories already classify as a server
/// fault. That matters beyond tidiness: a missing grade is not a zero, and
/// defaulting it to one would let a tutor silently register with a grade that
/// fails the competency threshold.
double readRequiredDecimal(Object? value, String field) {
  final parsed = readDecimal(value);
  if (parsed != null) return parsed;
  throw FormatException('expected a decimal for $field');
}
