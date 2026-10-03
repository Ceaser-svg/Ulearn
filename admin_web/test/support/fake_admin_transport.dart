import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A dio transport that answers from a handler instead of a network.
///
/// dio has no test adapter in this console's dependency set, and adding one
/// would be a heavier change than the behaviour under test. Answering at the
/// adapter layer still exercises the real transport: real headers, real status
/// classification, real refresh handling. Only the socket is gone.
class FakeAdminTransport implements HttpClientAdapter {
  FakeAdminTransport(this._handler);

  /// Every request that reached the transport, in order.
  final List<RequestOptions> requests = <RequestOptions>[];

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  /// The paths of every request that reached the transport, in order.
  List<String> get paths =>
      requests.map((options) => options.path).toList(growable: false);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// A JSON response for [FakeAdminTransport].
ResponseBody jsonResponse(Object? body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
