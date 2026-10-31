import 'package:baka/core/api_transport.dart';
import 'package:baka/models/token_response.dart';
import 'package:http/http.dart' as http;

class AuthApi {
  AuthApi(this.client, this.baseUrl);
  final http.Client client;
  final String Function() baseUrl;
  Future<TokenResponse?> refresh(String token) async {
    final uri = Uri.parse('${baseUrl()}/user/refresh');
    try {
      final response = await sendHttp(
        client,
        'POST',
        uri,
        data: {'refresh_token': token},
      );
      if (uri.origin != Uri.parse(baseUrl()).origin) {
        throw StateError('服务器已变更，请重试');
      }
      final data = decodeJson<Map<String, dynamic>>(response.body);
      ApiTransport.accepted(data);
      return TokenResponse.fromJson(data);
    } on ApiException catch (error) {
      if (error.statusCode == 401 ||
          error.statusCode == 403 ||
          error.code == 401 ||
          error.code == 403) {
        return null;
      }
      rethrow;
    }
  }
}
