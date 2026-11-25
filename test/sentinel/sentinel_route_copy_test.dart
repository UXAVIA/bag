import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/services/sentinel_service.dart';

void main() {
  const proxy = ProxyRoute(
    ProxyConfig(type: ProxyType.socks5, host: '10.0.0.5', port: 1080),
  );

  test('Tor waits for, then names, the built-in client', () {
    expect(sentinelRouteDownCopy(const TorRoute()), 'Waiting for Tor…');
    expect(
      sentinelRouteDownCopy(const TorRoute(), paused: true),
      "Paused — Tor couldn't connect",
    );
  });

  test('a reachable-in-principle proxy asks the user to check it', () {
    expect(sentinelRouteDownCopy(proxy), 'Waiting for proxy…');
    expect(
      sentinelRouteDownCopy(proxy, paused: true),
      'Paused — check your proxy to resume',
    );
  });

  test('unreadable proxy settings point at Wallets → Network, not the proxy', () {
    expect(
      sentinelRouteDownCopy(const MisconfiguredProxyRoute()),
      'Proxy settings unreadable…',
    );
    expect(
      sentinelRouteDownCopy(const MisconfiguredProxyRoute(), paused: true),
      'Paused — re-enter your proxy in Wallets → Network to resume',
    );
  });
}
