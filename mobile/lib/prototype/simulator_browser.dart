import 'dart:async';
import 'dart:io';

import '../shared/hosted/browser_auth.dart';
import '../shared/hosted/hosted_environment.dart';

/// Local simulator bridge so development sign-in uses the owner's Mac Chrome.
/// Only the one-use OAuth code crosses this loopback socket; exchange stays in app.
Future<String?> openSimulatorChrome(Uri authorization) async {
  if (HostedEnvironment.origin.host != 'app.builderlabstaging.xyz') {
    throw StateError('Simulator browser requires staging.');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18763);
  final state = authorization.queryParameters['state']!;
  final path = '/callback/$state';
  final parameters = Map<String, String>.from(authorization.queryParameters)
    ..remove('returnTo')
    ..['product'] = 'builderlab'
    ..['redirect_uri'] = 'http://127.0.0.1:18763$path';
  final login = authorization.replace(queryParameters: parameters);
  final result = Completer<String>();
  final subscription = server.listen((request) async {
    request.response.headers.set('Cache-Control', 'no-store');
    String? callbackResult;
    if (request.method != 'GET') {
      request.response.statusCode = 405;
    } else if (request.uri.path == '/start') {
      request.response.statusCode = 302;
      request.response.headers.set('Location', login.toString());
    } else if (request.uri.path == path &&
        request.uri.queryParameters['state'] == state &&
        request.uri.queryParametersAll.values.every(
          (values) => values.length == 1,
        ) &&
        !result.isCompleted) {
      final callback = Uri.parse(
        BrowserAuth.callback,
      ).replace(queryParameters: request.uri.queryParameters);
      callbackResult = callback.toString();
      request.response.write(
        'Sign-in returned to Buzz Remote Prototype. You can close this tab.',
      );
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
    if (callbackResult != null && !result.isCompleted) {
      result.complete(callbackResult);
    }
  });
  try {
    return await result.future.timeout(const Duration(minutes: 10));
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}
