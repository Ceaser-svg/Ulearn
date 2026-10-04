import 'package:flutter/foundation.dart';

/// One page of an admin list, as the backend's `Page` envelope describes it.
///
/// Everything a pager needs is derived here from `offset`, `limit`, `items`
/// and `total` using the same formula the backend uses for `has_more`, rather
/// than read out of the response. Deriving keeps a screen from disagreeing
/// with the pager about whether another page exists, and keeps the console
/// working against a response that predates a computed field.
@immutable
class AdminPage<T> {
  const AdminPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  /// A page with no rows, and no session to fetch any with.
  const AdminPage.empty()
    : items = const [],
      total = 0,
      limit = AdminPageRequest.defaultPageSize,
      offset = 0;

  factory AdminPage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    return AdminPage<T>(
      items: (json['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(parse)
          .toList(),
      total: json['total'] as int,
      limit: json['limit'] as int,
      offset: json['offset'] as int,
    );
  }

  final List<T> items;

  /// Rows matching the query in total, which may exceed [items] by more than
  /// one page.
  final int total;

  final int limit;
  final int offset;

  bool get isEmpty => items.isEmpty;

  bool get hasMore => offset + items.length < total;

  int get pageCount => (total / limit).ceil();

  /// One-based, matching the page the request asked for.
  int get pageNumber => (offset ~/ limit) + 1;

  /// One-based number of the first row on this page, or 0 when there is none.
  int get firstRowNumber => isEmpty ? 0 : offset + 1;

  int get lastRowNumber => offset + items.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdminPage<T> &&
          other.total == total &&
          other.limit == limit &&
          other.offset == offset &&
          listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(total, limit, offset, Object.hashAll(items));

  @override
  String toString() => 'AdminPage(page $pageNumber, ${items.length} of $total)';
}

/// An offset/limit page request.
///
/// Offset paging is the API's own contract (`PageParams`), so the console
/// speaks it instead of inventing a page number the server never sees.
@immutable
class AdminPageRequest {
  const AdminPageRequest({this.page = 1, this.limit = defaultPageSize});

  /// The largest page the API will serve. `PageParams.limit` rejects anything
  /// above it, so the console must not offer it.
  static const int maxPageSize = 100;

  /// The page size the console showed before paging existed, so the first page
  /// of a list is unchanged by paging being added.
  static const int defaultPageSize = 50;

  /// Page sizes an operator can choose. All within [maxPageSize].
  static const List<int> pageSizeOptions = <int>[10, 25, 50, maxPageSize];

  final int page;
  final int limit;

  int get offset => (page - 1) * limit;

  AdminPageRequest get next => AdminPageRequest(page: page + 1, limit: limit);

  AdminPageRequest get previous =>
      page <= 1 ? this : AdminPageRequest(page: page - 1, limit: limit);

  /// A page of the same size. Always the first page: a different size moves
  /// the rows, so staying on page 4 would show an unrelated window.
  AdminPageRequest withLimit(int newLimit) => AdminPageRequest(limit: newLimit);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdminPageRequest && other.page == page && other.limit == limit;

  @override
  int get hashCode => Object.hash(page, limit);

  @override
  String toString() => 'AdminPageRequest(page $page, limit $limit)';
}
