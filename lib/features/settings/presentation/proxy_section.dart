import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/network_route.dart';
import '../../../providers/network_settings_provider.dart';
import '../../../services/network/routed_http.dart';
import '../../../services/network/socks5_connect.dart';

/// What a "Test connection" run found out about the proxy in the form.
enum ProxyTestResult {
  connected,
  authRequired,
  authRejected,
  unreachable,
  requestFailed,
}

/// User-facing line for each [ProxyTestResult]. Static on purpose: nothing
/// from the error, and certainly no credential, can end up on screen.
String _proxyTestMessage(ProxyTestResult result) => switch (result) {
  ProxyTestResult.connected => 'Connected through proxy',
  ProxyTestResult.authRequired => 'This proxy needs a username and password.',
  ProxyTestResult.authRejected => 'Proxy rejected the username or password',
  ProxyTestResult.unreachable => 'Could not reach the proxy',
  ProxyTestResult.requestFailed => 'Proxy connected, but the request failed',
};

/// Maps what a failed test request threw (a [DioException] or the bare
/// error underneath it) to a [ProxyTestResult]. Never returns
/// [ProxyTestResult.connected]: success is a 2xx response, not an error.
///
/// [hadCredentials] says whether the form had a username and password, which
/// is what separates "needs a login" from "login refused" for an HTTP proxy's
/// 407. A SOCKS5 proxy says which one it is itself.
///
/// Driven by the typed errors from `socks5_connect.dart` where there are
/// any. The two HTTP-proxy cases have no type to match: a 407 on CONNECT is
/// an [HttpException] whose message contains `(407`, and on an absolute-form
/// request it is a response with status 407.
ProxyTestResult classifyProxyTestError(
  Object error, {
  required bool hadCredentials,
}) {
  ProxyTestResult authFor407() => hadCredentials
      ? ProxyTestResult.authRejected
      : ProxyTestResult.authRequired;

  Object cause = error;
  if (error is DioException) {
    if (error.response?.statusCode == 407) return authFor407();
    if (error.type == DioExceptionType.connectionTimeout) {
      return ProxyTestResult.unreachable;
    }
    cause = error.error ?? error;
  }

  // The SOCKS5 errors are SocketExceptions too, so they come first.
  if (cause is ProxyAuthRejected) return ProxyTestResult.authRejected;
  if (cause is ProxyAuthRequired) return ProxyTestResult.authRequired;
  if (cause is Socks5Exception) return ProxyTestResult.requestFailed;
  if (cause is HttpException && cause.message.contains('(407')) {
    return authFor407();
  }
  // Refused, unresolvable or timed out before any proxy answered.
  if (cause is SocketException) return ProxyTestResult.unreachable;
  return ProxyTestResult.requestFailed;
}

/// The Wallets tab's card for a user-supplied SOCKS5 or HTTP proxy (the Pro
/// layout's Network section).
class ProxySection extends ConsumerStatefulWidget {
  const ProxySection({super.key, @visibleForTesting this.testUrl});

  /// What "Test connection" requests. Defaults to the price endpoint.
  final String? testUrl;

  @override
  ConsumerState<ProxySection> createState() => _ProxySectionState();
}

class _ProxySectionState extends ConsumerState<ProxySection> {
  late ProxyType _type;
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _revealPassword = false;

  /// True while any async call is in flight, so a second tap can't
  /// interleave the notifier's awaits.
  bool _busy = false;
  bool _testing = false;

  /// Why the form can't be saved or tested.
  String? _formError;

  /// Outcome of the last save or remove.
  String? _notice;
  ProxyTestResult? _testResult;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(networkSettingsProvider).proxy;
    _type = saved?.type ?? ProxyType.socks5;
    if (saved != null) _fill(saved);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _fill(ProxyConfig config) {
    _host.text = config.host;
    _port.text = config.port.toString();
    _username.text = config.username ?? '';
    _password.text = config.password ?? '';
  }

  /// Reads the form. Returns the config, or sets [_formError] and returns
  /// null. Host and port are trimmed; a blank username or password is null.
  ProxyConfig? _readForm() {
    final host = _host.text.trim();
    final port = _port.text.trim();
    final username = _username.text.trim().isEmpty ? null : _username.text;
    final password = _password.text.trim().isEmpty ? null : _password.text;

    final error = ProxyConfig.validate(
      type: _type,
      host: host,
      port: port,
      username: username,
      password: password,
    );
    if (error != null) {
      setState(() => _formError = error);
      return null;
    }
    return ProxyConfig(
      type: _type,
      host: host,
      port: int.parse(port),
      username: username,
      password: password,
    );
  }

  void _clearMessages() {
    _formError = null;
    _notice = null;
    _testResult = null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(_clearMessages);
    final config = _readForm();
    if (config == null) return;

    setState(() => _busy = true);
    try {
      await ref.read(networkSettingsProvider.notifier).saveProxy(config);
      if (mounted) setState(() => _notice = 'Proxy saved.');
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _formError = e.message.toString());
    } catch (_) {
      if (mounted) {
        setState(() => _formError = 'Could not save the proxy settings.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    FocusScope.of(context).unfocus();
    // Removing the proxy in use drops the app to a direct connection, so
    // ask first (M-16), as the free layout's switch-off rows do.
    if (ref.read(networkSettingsProvider).useProxy) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove proxy?'),
          content: const Text(
            'Bag will connect directly until you set up Tor or a proxy.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _clearMessages();
      _busy = true;
    });
    try {
      await ref.read(networkSettingsProvider.notifier).clearProxy();
      if (!mounted) return;
      _host.clear();
      _port.clear();
      _username.clear();
      _password.clear();
      setState(() => _notice = 'Proxy removed.');
    } catch (_) {
      if (mounted) {
        setState(() => _formError = 'Could not remove the proxy settings.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(bool value) async {
    setState(() {
      _clearMessages();
      _busy = true;
    });
    try {
      await ref.read(networkSettingsProvider.notifier).setUseProxy(value);
    } on StateError {
      if (mounted) setState(() => _formError = 'Save a proxy first.');
    } catch (_) {
      if (mounted) {
        setState(() => _formError = 'Could not change the proxy setting.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    FocusScope.of(context).unfocus();
    setState(_clearMessages);
    final config = _readForm();
    if (config == null) return;

    setState(() {
      _busy = true;
      _testing = true;
    });
    final dio = buildRoutedDio(
      route: ProxyRoute(config),
      clearnetTimeout: const Duration(seconds: 10),
    );
    // A private route would otherwise wait the full 60 s for a proxy that
    // never answers; a test should give up much sooner.
    dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 15);
    ProxyTestResult result;
    try {
      await dio.get<Object?>(
        widget.testUrl ?? '${AppConstants.bitbagApiBase}/price',
      );
      result = ProxyTestResult.connected;
    } catch (e) {
      result = classifyProxyTestError(e, hadCredentials: config.hasCredentials);
    } finally {
      dio.close(force: true);
    }
    if (!mounted) return;
    setState(() {
      _testResult = result;
      _busy = false;
      _testing = false;
    });
  }

  /// The line under the switch: what is saved, or how to start.
  static String _summary(ProxyConfig? saved, {required bool unreadable}) {
    if (unreadable) {
      return 'Saved proxy could not be read — re-enter it or switch the '
          'proxy off.';
    }
    if (saved == null) {
      return 'Send everything through a SOCKS5 or HTTP proxy. '
          'Save one below to switch it on.';
    }
    return 'Saved: ${saved.label}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final settings = ref.watch(networkSettingsProvider);
    final saved = settings.proxy;
    // On, but nothing usable saved (main() could not read the entry): the
    // route fails closed, and the user must still be able to get out.
    final unreadable = settings.useProxy && saved == null;
    // Off with nothing saved: nothing to switch on or remove.
    final noProxy = !settings.useProxy && saved == null;

    final testResult = _testResult;
    final smallStyle = textTheme.bodySmall?.copyWith(height: 1.5);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.alt_route_outlined,
                color: AppColors.primary,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Use a custom proxy', style: textTheme.bodyLarge),
              ),
              Switch(
                key: const Key('proxy-switch'),
                value: settings.useProxy,
                // Switching off needs no saved config; switching on does.
                onChanged: _busy || noProxy ? null : _setEnabled,
                activeThumbColor: AppColors.primary,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _summary(saved, unreadable: unreadable),
            style: smallStyle?.copyWith(
              color: unreadable ? AppColors.negative : null,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ProxyType>(
            segments: const [
              ButtonSegment(value: ProxyType.socks5, label: Text('SOCKS5')),
              ButtonSegment(value: ProxyType.http, label: Text('HTTP')),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: _busy
                ? null
                : (s) => setState(() {
                    _type = s.first;
                    _clearMessages();
                  }),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('proxy-host'),
            controller: _host,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Host'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('proxy-port'),
            controller: _port,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Port'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('proxy-username'),
            controller: _username,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Username (optional)'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('proxy-password'),
            controller: _password,
            enabled: !_busy,
            obscureText: !_revealPassword,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password (optional)',
              suffixIcon: IconButton(
                icon: Icon(
                  _revealPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                tooltip: _revealPassword ? 'Hide password' : 'Show password',
                onPressed: () =>
                    setState(() => _revealPassword = !_revealPassword),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Save and Test connection wrap onto a second line on a narrow
              // phone (320 px); Remove keeps the right edge.
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      key: const Key('proxy-save'),
                      onPressed: _busy ? null : _save,
                      child: const Text('Save'),
                    ),
                    OutlinedButton(
                      key: const Key('proxy-test'),
                      onPressed: _busy ? null : _test,
                      child: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Test connection'),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('proxy-remove'),
                onPressed: _busy || noProxy ? null : _remove,
                child: const Text('Remove'),
              ),
            ],
          ),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            Text(
              _formError!,
              style: smallStyle?.copyWith(color: AppColors.negative),
            ),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 8),
            Text(_notice!, style: smallStyle),
          ],
          if (testResult != null) ...[
            const SizedBox(height: 8),
            Text(
              _proxyTestMessage(testResult),
              style: smallStyle?.copyWith(
                color: testResult == ProxyTestResult.connected
                    ? AppColors.positive
                    : AppColors.negative,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'The proxy sees which servers Bag connects to, but not what is '
            'sent — that stays encrypted. Proxy usernames and passwords '
            "travel unencrypted to the proxy, so only use credentials you "
            "don't use elsewhere.",
            style: smallStyle,
          ),
        ],
      ),
    );
  }
}
