import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Base of every failure [socks5Connect] reports. It is a [SocketException]
/// so existing "network error" handling treats it as a connection failure.
///
/// Messages never contain the username or password.
class Socks5Exception implements SocketException {
  const Socks5Exception(this.message);

  @override
  final String message;

  @override
  OSError? get osError => null;

  @override
  InternetAddress? get address => null;

  @override
  int? get port => null;

  @override
  String toString() => 'SocksException: $message';
}

/// RFC 1929: the proxy refused the username and password.
class ProxyAuthRejected extends Socks5Exception {
  const ProxyAuthRejected() : super('Proxy rejected the username or password');
}

/// The proxy demands authentication and we have no credentials to give.
class ProxyAuthRequired extends Socks5Exception {
  const ProxyAuthRequired() : super('Proxy requires a username and password');
}

/// The proxy answered the CONNECT with a non-zero reply code (RFC 1928 §6).
class ProxyConnectFailed extends Socks5Exception {
  const ProxyConnectFailed(this.replyCode)
    : super('Proxy could not connect to the target');

  final int replyCode;

  @override
  String toString() => 'SocksException: $message (reply code $replyCode)';
}

/// The proxy did not speak SOCKS5: wrong version byte, an unknown address
/// type, or the connection ended mid-reply.
class Socks5ProtocolError extends Socks5Exception {
  const Socks5ProtocolError(super.message);
}

/// A SOCKS5 tunnel, positioned just after the CONNECT reply. Use it as a
/// plain [Socket], or call [secure] to start TLS over it.
///
/// Whatever the proxy sends after the reply, including bytes that arrived in
/// the same chunk, is delivered on the stream first and in order.
class Socks5Tunnel extends Stream<Uint8List> implements Socket {
  Socks5Tunnel._(this._socket, this._subscription, List<int> leftover) {
    _controller = StreamController<Uint8List>(
      onPause: _subscription.pause,
      onResume: _subscription.resume,
      onCancel: _subscription.cancel,
    );
    if (leftover.isNotEmpty) _deliver(Uint8List.fromList(leftover));
    _subscription
      ..onData(_deliver)
      ..onError(_controller.addError)
      ..onDone(_controller.close);
  }

  final Socket _socket;
  final StreamSubscription<Uint8List> _subscription;
  late final StreamController<Uint8List> _controller;
  bool _receivedData = false;

  void _deliver(Uint8List data) {
    _receivedData = true;
    _controller.add(data);
  }

  /// Starts TLS over the tunnel. A TLS server never speaks first, so data
  /// that arrived before this call means the proxy is misbehaving, and it
  /// could not be handed to the TLS layer anyway.
  ///
  /// The handshake is bounded by [timeout]: a proxy that tunnels and then
  /// goes silent would otherwise hold the request open forever. On timeout a
  /// [SocketException] is thrown.
  ///
  /// Known limit: [SecureSocket.secure] detaches the underlying RawSocket
  /// from [Socket] and exposes no handle to it until the handshake ends, so
  /// a stalled handshake's file descriptor is released only when the proxy
  /// closes it. [destroy] is still called, and is a no-op by then.
  ///
  /// [context] is for tests; null uses the default context (system roots).
  Future<SecureSocket> secure(
    String host, {
    required Duration timeout,
    SecurityContext? context,
  }) async {
    if (_receivedData) {
      destroy();
      throw const Socks5ProtocolError('Unexpected data before TLS handshake');
    }
    try {
      final secured = await SecureSocket.secure(
        _socket,
        host: host,
        context: context,
      ).timeout(
        timeout,
        onTimeout: () =>
            throw const SocketException('TLS handshake timed out'),
      );
      unawaited(_subscription.cancel());
      return secured;
    } catch (_) {
      destroy();
      rethrow;
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding encoding) => _socket.encoding = encoding;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _socket.addStream(stream);

  @override
  InternetAddress get address => _socket.address;

  @override
  Future<dynamic> close() => _socket.close();

  @override
  // Not cancelling the subscription: the socket's own done event has to reach
  // the stream, or whoever listens never hears the connection ended.
  void destroy() => _socket.destroy();

  @override
  Future<dynamic> get done => _socket.done;

  @override
  Future<dynamic> flush() => _socket.flush();

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  int get port => _socket.port;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
}

/// Buffers a socket's bytes so replies can be read by exact length without
/// consuming anything that follows.
class _Reader {
  _Reader(Stream<Uint8List> stream, this._deadline) {
    subscription = stream.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> subscription;
  final DateTime _deadline;
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  List<int> take() {
    final rest = List<int>.of(_buffer);
    _buffer.clear();
    return rest;
  }

  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      final error = _error;
      if (error != null) throw error;
      if (_done) {
        throw const Socks5ProtocolError('Proxy closed the connection');
      }
      final remaining = _deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const SocketException('Proxy handshake timed out');
      }
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(
        remaining,
        onTimeout: () =>
            throw const SocketException('Proxy handshake timed out'),
      );
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }
}

/// Opens a SOCKS5 CONNECT tunnel to [targetHost]:[targetPort] through the
/// proxy at [proxy]:[proxyPort].
///
/// Unlike the `socks5_proxy` package, the target is sent as exactly the UTF-8
/// bytes of [targetHost] (ATYP 0x03, so the proxy resolves it) with no
/// trailing NUL, which strict proxies such as Xray, sing-box or gost would
/// otherwise try to resolve as part of the name.
///
/// Credentials are offered only when both [username] and [password] are
/// given. The socket is closed on every failure path.
///
/// [onSocket] receives the TCP socket to the proxy as soon as it is open, so
/// a caller can destroy it at once if the connection is cancelled mid-way;
/// [socks5Connect] then fails rather than waiting out its [timeout].
Future<Socks5Tunnel> socks5Connect({
  required InternetAddress proxy,
  required int proxyPort,
  required String targetHost,
  required int targetPort,
  String? username,
  String? password,
  Duration timeout = const Duration(seconds: 60),
  void Function(Socket socket)? onSocket,
}) async {
  final host = utf8.encode(targetHost);
  if (host.isEmpty || host.length > 255) {
    throw ArgumentError.value(targetHost, 'targetHost', 'must be 1-255 bytes');
  }
  if (targetPort < 0 || targetPort > 65535) {
    throw ArgumentError.value(targetPort, 'targetPort');
  }
  final auth = username != null && password != null
      ? (user: utf8.encode(username), pass: utf8.encode(password))
      : null;
  if (auth != null && (auth.user.length > 255 || auth.pass.length > 255)) {
    throw ArgumentError('Proxy username and password must each fit 255 bytes');
  }

  final deadline = DateTime.now().add(timeout);
  final socket = await Socket.connect(proxy, proxyPort, timeout: timeout);
  final reader = _Reader(socket, deadline);
  onSocket?.call(socket);
  try {
    // Greeting: no authentication, plus username/password when we have it.
    socket.add([0x05, auth == null ? 1 : 2, 0x00, if (auth != null) 0x02]);
    final method = await reader.read(2);
    if (method[0] != 0x05) {
      throw const Socks5ProtocolError('Proxy did not answer with SOCKS5');
    }
    switch (method[1]) {
      case 0x00:
        break;
      case 0x02:
        if (auth == null) throw const ProxyAuthRequired();
        final (:user, :pass) = auth;
        socket.add([0x01, user.length, ...user, pass.length, ...pass]);
        final status = await reader.read(2);
        if (status[0] != 0x01) {
          throw const Socks5ProtocolError('Unexpected authentication version');
        }
        if (status[1] != 0x00) throw const ProxyAuthRejected();
      case 0xFF:
        throw const ProxyAuthRequired();
      default:
        throw const Socks5ProtocolError('Unsupported authentication method');
    }

    socket.add([
      0x05,
      0x01, // CONNECT
      0x00,
      0x03, // domain name
      host.length,
      ...host,
      targetPort >> 8,
      targetPort & 0xff,
    ]);
    final head = await reader.read(4);
    if (head[0] != 0x05) {
      throw const Socks5ProtocolError('Proxy did not answer with SOCKS5');
    }
    if (head[1] != 0x00) throw ProxyConnectFailed(head[1]);
    final boundLength = switch (head[3]) {
      0x01 => 4,
      0x04 => 16,
      0x03 => (await reader.read(1))[0],
      _ => throw const Socks5ProtocolError('Unknown bound address type'),
    };
    await reader.read(boundLength + 2); // BND.ADDR + BND.PORT

    return Socks5Tunnel._(socket, reader.subscription, reader.take());
  } catch (_) {
    reader.subscription.cancel().ignore();
    socket.destroy();
    rethrow;
  }
}
