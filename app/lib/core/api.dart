import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';
import 'session.dart';

/// A readable error from the backend ("Insufficient CNY balance", "This verification request expired", ...).
class ApiError implements Exception {
  ApiError(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: apiBase,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 60),
      contentType: 'application/json',
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = ref.read(sessionProvider).token;
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
        handler.next(options);
      },
      onError: (e, handler) {
        // Expired or revoked token: go back to sign-in.
        if (e.response?.statusCode == 401 && e.requestOptions.path != '/auth/login') {
          ref.read(sessionProvider.notifier).signOut();
        }
        handler.next(e);
      },
    ),
  );
  return dio;
});

class Api {
  Api(this._dio);
  final Dio _dio;

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => _dio.get(path, queryParameters: query));
  Future<dynamic> post(String path, [Object? body]) => _wrap(() => _dio.post(path, data: body ?? {}));
  Future<List<int>> bytes(String path) async =>
      List<int>.from(await _wrap(() => _dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes))));

  Future<dynamic> _wrap(Future<Response> Function() call) async {
    try {
      return (await call()).data;
    } on DioException catch (e) {
      final data = e.response?.data;
      final detail = data is Map ? data['detail'] : null;
      final msg = detail is String
          ? detail
          : detail is List && detail.isNotEmpty
          ? (detail.first['msg'] ?? 'Invalid input').toString()
          : e.type == DioExceptionType.connectionError
          ? 'Can\'t reach MoneyMate. Is the backend running?'
          : 'Something went wrong';
      throw ApiError(msg, e.response?.statusCode);
    }
  }
}

final apiProvider = Provider<Api>((ref) => Api(ref.watch(dioProvider)));
