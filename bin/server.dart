import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Configure routes.
final _router = Router()
  ..get('/', _rootHandler)
  ..get('/echo/<message>', _echoHandler);

Response _rootHandler(Request req) {
  return Response.ok('Hello, World!\n');
}

Response _echoHandler(Request request) {
  final message = request.params['message'];
  return Response.ok('$message\n');
}

class SignalServer {
  Timer? _timer;
  int _counter = 0;
  bool _sinusMode = true;
  double _amplitude = 3.0;
  double _period = 1.0; // Default period in seconds
  int _frequency = 65; // Default frequency in milliseconds
  List<List<double>> _dataArrays = [[], []];

  final List<WebSocketChannel> _clients = [];

  void handleWebSocketMessage(WebSocketChannel ws) {
    _clients.add(ws);
    ws.stream.listen(
      (message) {
        var decodedMessage = jsonDecode(message);

        if (decodedMessage['type'] == 'settings') {
          _updateSettings(decodedMessage['settings']);
        } else if (decodedMessage['type'] == 'stream') {
          _handleData(decodedMessage['data']);
        } else if (decodedMessage['type'] == 'manual') {
          _updateMode(decodedMessage['mode']);
        }
      },
      onDone: () {
        _clients.remove(ws);
        _sinusMode = false;
        _dataArrays = [[], []];
        _counter = 0;
        _timer?.cancel();
        _timer = null;
      },
    );
  }

  void _updateSettings(Map<String, dynamic> settings) {
    if (settings.containsKey('frequency')) {
      _frequency = settings['frequency'];
      _restartTimer();
    }
    if (settings.containsKey('amplitude')) {
      _amplitude = settings['amplitude'];
    }
    if (settings.containsKey('period')) {
      _period = settings['period'];
    }
  }

  void _handleData(List<List<double>> dataArrays) {
    _dataArrays = dataArrays;
    _sinusMode = false;
    _restartTimer();
  }

  void _updateMode(String mode) {
    if (mode == 'sinus' || mode == 'data') {
      _sinusMode = mode == 'sinus';
      _restartTimer();
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(milliseconds: _frequency), (timer) {
      if (_sinusMode) {
        var sinValue = _amplitude * sin(_counter * 2 * pi * _period / 180);
        var cosValue = _amplitude * cos(_counter * 2 * pi * _period / 180);
        var message = '$sinValue,$cosValue,$sinValue';
        _broadcast(message);
        _counter++;
      } else {
        for (var i = 0; i < _dataArrays[0].length; i++) {
          var message = '${_dataArrays[0][i]},${_dataArrays[1][i]},0';
          _broadcast(message);
        }
      }
    });
  }

  void _restartTimer() {
    _timer?.cancel();
    _startTimer();
  }

  void _broadcast(String message) {
    for (var client in _clients) {
      client.sink.add(message);
    }
  }
}

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  var signalServer = SignalServer();

  var wsHandler = webSocketHandler((webSocket) {
    signalServer.handleWebSocketMessage(webSocket);
  });

  var staticHandler = createStaticHandler('web', defaultDocument: 'index.html');

  var handler = Cascade().add(wsHandler).add(staticHandler).handler;

  // Configure a pipeline that logs requests.
  // final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
}
