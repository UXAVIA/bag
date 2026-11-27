import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/network_route.dart';
import 'package:bag/models/network_settings.dart';

const _config = ProxyConfig(
  type: ProxyType.http,
  host: 'proxy.lan',
  port: 3128,
);

void main() {
  group('NetworkSettings.route', () {
    test('defaults to direct', () {
      expect(const NetworkSettings().route, const DirectRoute());
    });

    test('Tor wins over a proxy', () {
      const s = NetworkSettings(useTor: true, useProxy: true, proxy: _config);
      expect(s.route, const TorRoute());
    });

    test('use_proxy with a config is a ProxyRoute', () {
      const s = NetworkSettings(useProxy: true, proxy: _config);
      expect(s.route, const ProxyRoute(_config));
    });

    test('use_proxy without a config fails closed', () {
      const s = NetworkSettings(useProxy: true);
      expect(s.route, const MisconfiguredProxyRoute());
    });

    test('a saved config without use_proxy stays direct', () {
      const s = NetworkSettings(proxy: _config);
      expect(s.route, const DirectRoute());
    });
  });

  group('NetworkSettings.copyWith', () {
    test('keeps the proxy when not mentioned', () {
      const s = NetworkSettings(proxy: _config);
      expect(s.copyWith(useTor: true).proxy, _config);
    });

    test('can set and clear the proxy', () {
      const s = NetworkSettings();
      final set = s.copyWith(proxy: () => _config);
      expect(set.proxy, _config);
      expect(set.copyWith(proxy: () => null).proxy, isNull);
    });
  });
}
