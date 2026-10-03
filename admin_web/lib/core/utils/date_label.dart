/// Formats a timestamp as `YYYY-MM-DD`.
///
/// Every admin list sorts by a timestamp an operator reads as a date; the time
/// of day is never shown, and `intl` is not a dependency of this console.
String formatDateLabel(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
