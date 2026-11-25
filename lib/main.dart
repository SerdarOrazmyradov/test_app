// main.dart
//
// A lightweight in-app browser (flutter_inappwebview) that intercepts link
// clicks and ONLY reacts to direct Rutube video URLs:
//
//     https://rutube.ru/video/<id>
//     https://www.rutube.ru/video/<id>/
//     https://m.rutube.ru/video/<id>
//
// Everything else (search pages, other Rutube sections, YouTube, VK, …)
// navigates normally inside the browser and never triggers the modal.
//
// pubspec.yaml:
//   dependencies:
//     flutter: {sdk: flutter}
//     flutter_inappwebview: ^6.1.5
//
// Android: <uses-permission android:name="android.permission.INTERNET"/>
// iOS: nothing special for this demo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RutubeFilterApp());
}

class RutubeFilterApp extends StatelessWidget {
  const RutubeFilterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rutube Link Filter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
      ),
      home: const BrowserPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. Link validation helpers (pure functions, easy to unit-test)
// ---------------------------------------------------------------------------

class RutubeLink {
  RutubeLink._();

  /// The ONLY URL shape we accept. Anchored with ^ ... $ so that
  /// `/channel/`, `/tags/`, `/feeds/`, `/pl/`, `/video/abc/extra/` etc. fail.
  static final RegExp videoPattern = RegExp(
    r'^https?://(?:www\.|m\.)?rutube\.ru/video/[a-zA-Z0-9_-]+/?$',
  );

  static final RegExp _videoIdPattern =
      RegExp(r'^/video/([a-zA-Z0-9_-]+)/?$');

  /// Query keys used by search engines to wrap the real destination.
  static const List<String> _redirectQueryKeys = <String>[
    'url',
    'q',
    'u',
    'target',
    'to',
    'redirect',
    'uddg',
  ];

  /// True only for a *direct* Rutube video page.
  ///
  /// Query string and fragment are stripped first, so
  /// `https://rutube.ru/video/abc123/?p=xyz` still counts as a video link,
  /// while `https://rutube.ru/channel/123/` never does.
  static bool isVideoUrl(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return videoPattern.hasMatch(_stripQueryAndFragment(uri));
  }

  static String? extractVideoId(Uri uri) {
    final match = _videoIdPattern.firstMatch(uri.path);
    return match?.group(1);
  }

  /// Canonical, cleaned-up representation of the accepted link.
  static String canonicalUrl(Uri uri) {
    final id = extractVideoId(uri);
    return id == null ? uri.toString() : 'https://rutube.ru/video/$id/';
  }

  /// Detects "redirector" endpoints such as:
  ///   https://www.google.com/url?q=<encoded>
  ///   https://search.brave.com/go?url=<encoded>
  ///   https://duckduckgo.com/l/?uddg=<encoded>
  static bool isRedirectWrapper(Uri uri) {
    final path = uri.path.toLowerCase();
    final isRedirectPath = path == '/url' ||
        path.startsWith('/url/') ||
        path == '/go' ||
        path.startsWith('/go/') ||
        path == '/l' ||
        path.startsWith('/l/') ||
        path.contains('/redirect');
    return isRedirectPath;
  }

  /// If the redirector already exposes the destination in its query string,
  /// read it without any network traffic.
  static Uri? targetFromQuery(Uri uri) {
    for (final key in _redirectQueryKeys) {
      final raw = uri.queryParameters[key];
      if (raw == null || raw.isEmpty) continue;
      final candidate = Uri.tryParse(raw);
      if (candidate != null &&
          (candidate.scheme == 'http' || candidate.scheme == 'https')) {
        return candidate;
      }
    }
    return null;
  }

  static String _stripQueryAndFragment(Uri uri) {
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      path: uri.path,
    ).toString();
  }
}

// ---------------------------------------------------------------------------
// 2. Background redirect resolution
// ---------------------------------------------------------------------------

const String _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

bool _isRedirectStatus(int code) =>
    code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

/// Follows HTTP redirects manually (HEAD requests, no body download) so we can
/// inspect the FINAL destination of something like `search.brave.com/go?...`
/// without ever letting the WebView load it.
Future<Uri?> resolveRedirectChain(Uri start, {int maxHops = 5}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  Uri current = start;
  try {
    for (var hop = 0; hop < maxHops; hop++) {
      final request = await client.headUrl(current);
      request.followRedirects = false; // we want to see the raw 3xx
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      final response = await request.close();
      await response.drain<void>();

      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || !_isRedirectStatus(response.statusCode)) {
        return current; // no more hops -> this is the destination
      }

      final next = current.resolve(location);
      if (next == current) return current; // loop guard
      current = next;
    }
    return current;
  } catch (_) {
    return null; // network failure -> caller falls back to "allow"
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// 3. The browser page
// ---------------------------------------------------------------------------

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  static const String _homeUrl = 'https://search.brave.com/';

  final GlobalKey _webViewKey = GlobalKey();
  InAppWebViewController? _webViewController;

  double _progress = 0.0;
  bool _isLoading = true;
  bool _sheetVisible = false; // prevents stacking several bottom sheets

  // -------------------------------------------------------------------------
  // Interception pipeline
  // -------------------------------------------------------------------------

  /// Called for EVERY navigation the WebView is about to perform.
  /// Returning CANCEL keeps the user where they are; ALLOW lets it load.
  Future<NavigationActionPolicy> _interceptNavigation(Uri uri) async {
    // (a) Direct hit — the clicked URL already is a Rutube video page.
    if (RutubeLink.isVideoUrl(uri)) {
      await _showVideoSheet(uri);
      return NavigationActionPolicy.CANCEL;
    }

    // (b) Redirect wrapper — resolve the real destination first.
    if (RutubeLink.isRedirectWrapper(uri)) {
      final target = await _resolveRedirectTarget(uri);
      if (target != null && RutubeLink.isVideoUrl(target)) {
        await _showVideoSheet(target);
        return NavigationActionPolicy.CANCEL;
      }
      // Redirect goes somewhere we don't care about -> browse normally.
      return NavigationActionPolicy.ALLOW;
    }

    // (c) Anything else: search pages, `/channel/`, `/tags/`, YouTube, VK,
    //     TikTok, … They load inside the browser and NEVER open the modal.
    return NavigationActionPolicy.ALLOW;
  }

  /// Best-effort resolution of a redirector URL to its final target.
  Future<Uri?> _resolveRedirectTarget(Uri redirector) async {
    // Cheap path: the destination is already in the query string.
    final hinted = RutubeLink.targetFromQuery(redirector);
    if (hinted != null && RutubeLink.isVideoUrl(hinted)) return hinted;

    // Expensive path: follow the 3xx chain in the background.
    final resolved = await resolveRedirectChain(redirector);
    if (resolved != null && resolved != redirector) return resolved;

    return hinted;
  }

  Future<void> _showVideoSheet(Uri uri) async {
    if (!mounted || _sheetVisible) return;

    final prettyUrl = RutubeLink.canonicalUrl(uri);
    final videoId = RutubeLink.extractVideoId(uri) ?? '—';

    _sheetVisible = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => _VideoMatchSheet(url: prettyUrl, videoId: videoId),
      );
    } finally {
      _sheetVisible = false;
    }
  }

  // -------------------------------------------------------------------------
  // Small navigation helpers
  // -------------------------------------------------------------------------

  Future<void> _safeGoBack() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      if (await controller.canGoBack()) await controller.goBack();
    } catch (_) {}
  }

  Future<void> _safeGoForward() async {
    final controller = _webViewController;
    if (controller == null) return;
    try {
      if (await controller.canGoForward()) await controller.goForward();
    } catch (_) {}
  }

  void _goHome() {
    _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(_homeUrl)),
    );
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: const Text('Rutube Filter Browser'),
        actions: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: _safeGoBack,
          ),
          IconButton(
            tooltip: 'Forward',
            icon: const Icon(Icons.arrow_forward_ios, size: 18),
            onPressed: _safeGoForward,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () => _webViewController?.reload(),
          ),
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined),
            onPressed: _goHome,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _isLoading && _progress < 1.0
              ? LinearProgressIndicator(value: _progress, minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: SafeArea(
        child: InAppWebView(
          key: _webViewKey,
          initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            supportZoom: false,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
          ),
          onWebViewCreated: (controller) {
            _webViewController = controller;
          },
          onLoadStart: (controller, url) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _progress = 0.0;
            });
          },
          onProgressChanged: (controller, progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100.0);
          },
          onLoadStop: (controller, url) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _progress = 1.0;
            });
          },
          // *** The heart of the filter ***
          // Fires BEFORE any navigation happens (main frame + sub frames).
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final rawUrl = navigationAction.request.url;
            if (rawUrl == null) return NavigationActionPolicy.ALLOW;

            final uri = Uri.tryParse(rawUrl.toString());
            if (uri == null) return NavigationActionPolicy.ALLOW;

            return _interceptNavigation(uri);
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Result sheet
// ---------------------------------------------------------------------------

class _VideoMatchSheet extends StatelessWidget {
  const _VideoMatchSheet({required this.url, required this.videoId});

  final String url;
  final String videoId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Color(0xFF2E7D32),
                  size: 44,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Rutube video detected',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'The link was intercepted before the browser could open it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F8E9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFC5E1A5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'VIDEO URL',
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF33691E),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    url,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Video ID: $videoId',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Send to Proxy/Server'),
              onPressed: () {
                // Grab the messenger before the sheet's context is disposed.
                final messenger = ScaffoldMessenger.of(context);
                Navigator.of(context).pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Queued for proxy: $url'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}