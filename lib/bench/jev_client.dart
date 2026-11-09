/// TypeSafe AI System One API(Jev)の最小クライアント(ベンチマーク用)。
/// 仕様: POST https://api.typesafe.ai/v1/systemone、Bearer 認証、
/// 429/529 は指数バックオフで再試行(docs.typesafe.ai/api)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class JevResponse {
  final Map<String, dynamic> body;
  final int latencyMs;
  final int attempts;

  const JevResponse(this.body, this.latencyMs, this.attempts);

  Map<String, dynamic> get answers =>
      (body['answers'] as Map).cast<String, dynamic>();
  int get inputTokens => (body['usage']?['input_tokens'] as int?) ?? 0;
}

class JevException implements Exception {
  final int status;
  final String message;
  const JevException(this.status, this.message);
  @override
  String toString() => 'JevException($status): $message';
}

class JevClient {
  final String apiKey;
  final Uri endpoint;
  final HttpClient _http;
  final int maxAttempts;

  JevClient({
    required this.apiKey,
    Uri? endpoint,
    this.maxAttempts = 6,
    Duration timeout = const Duration(seconds: 60),
  }) : endpoint = endpoint ?? Uri.parse('https://api.typesafe.ai/v1/systemone'),
       _http = HttpClient()..connectionTimeout = timeout;

  /// レコードの request(model/state/questions)をそのまま送る。
  Future<JevResponse> ask(Map<String, dynamic> request) async {
    final payload = utf8.encode(jsonEncode(request));
    var delay = const Duration(milliseconds: 500);
    for (var attempt = 1; ; attempt++) {
      final sw = Stopwatch()..start();
      try {
        final req = await _http.postUrl(endpoint);
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(payload);
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        sw.stop();
        if (res.statusCode == 200) {
          return JevResponse(
            (jsonDecode(text) as Map).cast<String, dynamic>(),
            sw.elapsedMilliseconds,
            attempt,
          );
        }
        final retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (!retryable || attempt >= maxAttempts) {
          throw JevException(res.statusCode, text);
        }
      } on SocketException catch (e) {
        if (attempt >= maxAttempts) throw JevException(0, e.message);
      } on HttpException catch (e) {
        if (attempt >= maxAttempts) throw JevException(0, e.message);
      }
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }

  void close() => _http.close(force: true);
}
