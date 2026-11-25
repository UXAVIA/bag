import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A loopback HTTP server that counts requests and answers `{"ok":true}`.
class TargetServer {
  TargetServer._(this._server) {
    _server.listen((request) {
      hits++;
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"ok":true}');
      request.response.close();
    }, onError: (_) {}); // failed TLS handshakes land here
  }

  final HttpServer _server;
  int hits = 0;

  int get port => _server.port;

  static Future<TargetServer> start() async =>
      TargetServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  /// The same server over TLS, presenting [certPem] / [keyPem].
  static Future<TargetServer> startSecure({
    required String certPem,
    required String keyPem,
  }) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    return TargetServer._(
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context),
    );
  }

  Future<void> close() => _server.close(force: true);
}

/// Buffers a socket's bytes so a handshake can read exact lengths, then hands
/// the connection over to raw forwarding.
class _ByteReader {
  _ByteReader(Socket socket) {
    socket.listen(
      (data) {
        final forward = _passthrough;
        if (forward != null) {
          forward(data);
          return;
        }
        _buffer.addAll(data);
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (_) {
        _done = true;
        _wake();
      },
    );
  }

  final List<int> _buffer = [];
  Completer<void>? _waiter;
  bool _done = false;
  void Function(List<int>)? _passthrough;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      if (_done) throw const SocketException('closed mid-read');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  /// Reads up to and including the blank line that ends an HTTP head.
  Future<String> readHead() async {
    while (true) {
      final text = latin1.decode(_buffer, allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end != -1) {
        _buffer.removeRange(0, end + 4);
        return text.substring(0, end);
      }
      if (_done) throw const SocketException('closed mid-head');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
  }

  /// Forwards everything buffered so far and every later chunk to [forward].
  void passthrough(void Function(List<int>) forward) {
    if (_buffer.isNotEmpty) forward(List.of(_buffer));
    _buffer.clear();
    _passthrough = forward;
  }
}

/// A SOCKS5 proxy (RFC 1928 + RFC 1929). By default it tunnels every CONNECT
/// to `127.0.0.1:targetPort`, whatever host the client asked for.
class FakeSocks5Proxy {
  FakeSocks5Proxy._(
    this._server,
    this._username,
    this._password,
    this._target,
    this._connectReplyCode,
    this._payload,
    this._byteByByte,
    this._silentAfterConnect,
  ) {
    _server.listen(_handle);
  }

  final ServerSocket _server;
  final String? _username;
  final String? _password;
  final int _target;
  final int _connectReplyCode;
  final List<int>? _payload;
  final bool _byteByByte;
  final bool _silentAfterConnect;

  /// TCP connections accepted, whatever they then sent.
  int connections = 0;

  /// Target hosts from ATYP 0x03 requests: the exact bytes received, decoded
  /// as UTF-8, so a stray NUL would show up here.
  final List<String> connectHosts = [];

  /// `(username, password)` pairs received in the RFC 1929 sub-negotiation.
  final List<(String, String)> authAttempts = [];

  int get port => _server.port;

  /// [connectReplyCode] answers every CONNECT with that failure code instead
  /// of tunnelling. [payload] answers a CONNECT with the success reply and
  /// those bytes written in the same write (no tunnelling at all).
  /// [byteByByte] writes the whole answer one byte per TCP segment.
  /// [silentAfterConnect] answers a CONNECT with the success reply and then
  /// never sends another byte, like a stalled upstream: a TLS client waits
  /// forever for the ServerHello. [port] binds a fixed port on 127.0.0.1
  /// (0, the default, picks a free one).
  static Future<FakeSocks5Proxy> start({
    String? username,
    String? password,
    required int targetPort,
    int connectReplyCode = 0,
    List<int>? payload,
    bool byteByByte = false,
    bool silentAfterConnect = false,
    int port = 0,
  }) async => FakeSocks5Proxy._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
    username,
    password,
    targetPort,
    connectReplyCode,
    payload,
    byteByByte,
    silentAfterConnect,
  );

  Future<void> close() => _server.close();

  Future<void> _write(Socket client, List<int> bytes) async {
    if (!_byteByByte) {
      client.add(bytes);
      await client.flush();
      return;
    }
    for (final byte in bytes) {
      client.add([byte]);
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> _handle(Socket client) async {
    connections++;
    client.setOption(SocketOption.tcpNoDelay, true);
    final reader = _ByteReader(client);
    try {
      final greeting = await reader.read(2);
      final methods = await reader.read(greeting[1]);
      final needsAuth = _username != null;
      if (needsAuth && !methods.contains(0x02)) {
        await _write(client, [0x05, 0xFF]); // no acceptable method
        await client.close();
        return;
      }
      await _write(client, [0x05, needsAuth ? 0x02 : 0x00]);

      if (needsAuth) {
        await reader.read(1); // sub-negotiation version
        final user = utf8.decode(await reader.read((await reader.read(1))[0]));
        final pass = utf8.decode(await reader.read((await reader.read(1))[0]));
        authAttempts.add((user, pass));
        final ok = user == _username && pass == _password;
        await _write(client, [0x01, ok ? 0x00 : 0x01]);
        if (!ok) {
          await client.close();
          return;
        }
      }

      final request = await reader.read(4); // VER CMD RSV ATYP
      if (request[3] == 0x03) {
        final name = utf8.decode(await reader.read((await reader.read(1))[0]));
        connectHosts.add(name);
      } else {
        await reader.read(request[3] == 0x01 ? 4 : 16);
      }
      await reader.read(2); // port

      if (_connectReplyCode != 0) {
        await _write(client, [
          0x05,
          _connectReplyCode,
          0x00,
          0x01,
          0, 0, 0, 0, 0, 0, //
        ]);
        await client.close();
        return;
      }

      const success = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
      if (_silentAfterConnect) {
        // The ClientHello is buffered and never answered.
        await _write(client, success);
        return;
      }
      final payload = _payload;
      if (payload != null) {
        await _write(client, [...success, ...payload]);
        await client.close();
        return;
      }

      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _target,
      );
      await _write(client, success);
      reader.passthrough(upstream.add);
      upstream.listen(
        client.add,
        onDone: client.close,
        onError: (_) => client.destroy(),
      );
      client.done.catchError((_) {}).whenComplete(upstream.destroy);
    } catch (_) {
      client.destroy();
    }
  }
}

/// Orbot's SOCKS port, which a 1.3.5 user may still have open.
const orbotSocksPort = 9050;

/// A [FakeSocks5Proxy] on 127.0.0.1:9050, standing in for an Orbot left
/// running after the upgrade: a test asserts it gets no connection.
///
/// Test files run in parallel and more than one stands Orbot up, each for a
/// moment, so a taken port is retried for a while. A port taken for longer
/// (a local Tor or Orbot) fails the test: it needs the port free.
Future<FakeSocks5Proxy> startOrbotStandIn({required int targetPort}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    try {
      return await FakeSocks5Proxy.start(
        targetPort: targetPort,
        port: orbotSocksPort,
      );
    } on SocketException catch (e) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Port $orbotSocksPort is taken on this host (a local Tor or '
          'Orbot?); this test needs it free to stand in for Orbot: $e',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// An HTTP proxy. Absolute-form requests are forwarded to
/// `127.0.0.1:targetPort`; CONNECT is answered with 200 and the connection is
/// then closed, which is enough to see what the client sent without TLS.
class FakeHttpProxy {
  FakeHttpProxy._(this._server, this._username, this._password, this._target) {
    _server.listen(_handle);
  }

  final ServerSocket _server;
  final String? _username;
  final String? _password;
  final int _target;

  /// `CONNECT host:443 HTTP/1.1` or `GET http://… HTTP/1.1`.
  final List<String> requestLines = [];

  /// The `Proxy-Authorization` header of each request, or null when absent.
  final List<String?> proxyAuthHeaders = [];

  int get port => _server.port;

  static Future<FakeHttpProxy> start({
    String? username,
    String? password,
    required int targetPort,
    InternetAddress? bindAddress,
  }) async => FakeHttpProxy._(
    await ServerSocket.bind(bindAddress ?? InternetAddress.loopbackIPv4, 0),
    username,
    password,
    targetPort,
  );

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final reader = _ByteReader(client);
    try {
      final lines = (await reader.readHead()).split('\r\n');
      final requestLine = lines.first;
      requestLines.add(requestLine);
      String? auth;
      for (final line in lines.skip(1)) {
        if (line.toLowerCase().startsWith('proxy-authorization:')) {
          auth = line.substring(line.indexOf(':') + 1).trim();
        }
      }
      proxyAuthHeaders.add(auth);

      if (_username != null) {
        final expected =
            'Basic ${base64Encode(utf8.encode('$_username:$_password'))}';
        if (auth != expected) {
          client.write(
            'HTTP/1.1 407 Proxy Authentication Required\r\n'
            'Proxy-Authenticate: Basic realm="bag-test"\r\n'
            'Content-Length: 0\r\n'
            'Connection: close\r\n\r\n',
          );
          await client.flush();
          await client.close();
          return;
        }
      }

      final parts = requestLine.split(' ');
      if (parts[0] == 'CONNECT') {
        client.write('HTTP/1.1 200 Connection established\r\n\r\n');
        await client.flush();
        await client.close();
        return;
      }

      // Forward as origin-form to the target and relay the answer.
      final path = Uri.parse(parts[1]).path;
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _target,
      );
      final headers = lines
          .skip(1)
          .where(
            (l) =>
                !l.toLowerCase().startsWith('proxy-') &&
                !l.toLowerCase().startsWith('connection:'),
          )
          .join('\r\n');
      upstream.write(
        '${parts[0]} ${path.isEmpty ? '/' : path} HTTP/1.1\r\n'
        '$headers\r\nConnection: close\r\n\r\n',
      );
      upstream.listen(
        client.add,
        onDone: client.close,
        onError: (_) => client.destroy(),
      );
    } catch (_) {
      client.destroy();
    }
  }
}

/// Accepts TCP connections and never sends a byte, like a proxy that hangs
/// mid-handshake. Records when the client side closes a connection.
class SilentServer {
  SilentServer._(this._server) {
    _server.listen((socket) {
      socket.listen(
        (_) {},
        onDone: _markClosed,
        onError: (_) => _markClosed(),
      );
    });
  }

  final ServerSocket _server;
  final _closed = Completer<void>();

  int get port => _server.port;

  /// Completes once a client has closed (or reset) its connection.
  Future<void> get clientClosed => _closed.future;

  void _markClosed() {
    if (!_closed.isCompleted) _closed.complete();
  }

  static Future<SilentServer> start() async =>
      SilentServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> close() => _server.close();
}
