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

  StreamController<String> dataBufferController = StreamController();

  Stream<String> get dataBuffer => dataBufferController.stream;

  StreamSubscription? dataBufferSubscription;

  final List<WebSocketChannel> _clients = [];

  void handleWebSocketMessage(WebSocketChannel ws) {
    _clients.add(ws);
    ws.stream.listen(
      (message) {
        var decodedMessage = jsonDecode(message);

        if (decodedMessage['type'] == 'settings') {
          _updateSettings(decodedMessage['settings']);
        } else if (decodedMessage['type'] == 'stream_start') {
          _timer?.cancel();
          _timer = null;
          dataBufferSubscription?.cancel();
          dataBufferSubscription ??= dataBufferController.stream.listen((data) {
            ws.sink.add(data);
          });
        } else if (decodedMessage['type'] == 'stream_data') {
          final List<double> ecg = decodedMessage['ecg_data'].cast<double>();
          final List<double> ppg = decodedMessage['ppg_data'].cast<double>();
          _handleData(ecg, ppg);
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

    print('Change settings: $settings');
  }

  void _handleData(List<double> ecgData, List<double> ppgData) {
    for (var pair in zip(ecgData, ppgData)) {
      dataBufferController.add('${pair[0]},${pair[1]}');
    }
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

Iterable<List<T>> zip<T>(List<T> a, List<T> b) sync* {
  int length = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < length; i++) {
    yield [a[i], b[i]];
  }
}
