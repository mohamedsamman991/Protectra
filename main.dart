// lib/main.dart
//
// Protectra — Single-file full app (Parent/Child, pairing, blocked sites, link checker,
// Safe WebView, usage timers, and MethodChannel to start/stop native VPN service).
//
// Paste this file into lib/main.dart of your Flutter project protectra_v5_new.
//
// Keep packages in pubspec.yaml: provider, shared_preferences, url_launcher, uuid, webview_flutter
// and run: flutter pub get
//
// NOTE: This file preserves your app logic but applies small fixes where required
// (improved domain extraction, MethodChannel for VPN control).
//
// ------------------- Imports -------------------
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ------------------- Constants & Channel -------------------

// Method channel to communicate with Android native VPN service (MainActivity.kt).
// If native side is not present yet, calling methods will throw; catch PlatformException.
const MethodChannel _vpnChannel = MethodChannel('protectra_vpn_channel');

// ------------------- Main -------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyApp(prefs: prefs));
}

// ------------------- MyApp -------------------
class MyApp extends StatelessWidget {
  final SharedPreferences prefs;
  const MyApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(prefs),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Protectra — Parental Control',
        theme: ThemeData(
          scaffoldBackgroundColor: const Color(0xFFFDFBE8),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6D9DC5),
            primary: const Color(0xFF9BD3E6),
            secondary: const Color(0xFF6D9DC5),
            surface: const Color(0xFFFDFBE8),
            error: const Color(0xFF447A9C),
            onPrimary: Colors.white,
            onSecondary: Colors.black87,
            onSurface: Colors.black87,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF9BD3E6),
            foregroundColor: Colors.white,
            centerTitle: true,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6D9DC5),
              foregroundColor: Colors.white,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF447A9C)),
          ),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: Color(0xFF6D9DC5),
            contentTextStyle: TextStyle(color: Colors.white),
          ),
          progressIndicatorTheme: const ProgressIndicatorThemeData(
            color: Color(0xFF447A9C),
          ),
        ),
        home: const LandingPage(),
      ),
    );
  }
}

// ------------------- AppState -------------------
// Central app state and persistence
class AppState extends ChangeNotifier {
  final SharedPreferences prefs;

  // Device info
  String deviceId = '';
  String? pairedDeviceId;
  String parentPin = '';
  String? pairingCode;

  // Timer usage
  int dailyLimitMinutes = 60;
  int usedMinutesToday = 0;
  Timer? _tick;
  DateTime lastTick = DateTime.now();

  // Link Checker history
  List<LinkCheckEntry> linkHistory = [];

  // Blocked websites
  List<String> blockedSites = [];

  AppState(this.prefs) {
    parentPin = prefs.getString('parentPin') ?? '';
    dailyLimitMinutes = prefs.getInt('dailyLimitMinutes') ?? 60;
    usedMinutesToday = prefs.getInt('usedMinutesToday') ?? 0;
    deviceId = prefs.getString('deviceId') ?? const Uuid().v4();
    prefs.setString('deviceId', deviceId);
    pairedDeviceId = prefs.getString('pairedDeviceId');
    pairingCode = prefs.getString('pairingCode');
    _loadLinkHistory();
    _loadBlockedSites();
  }

  // ------------------- Pairing -------------------
  Future<void> setPairedDeviceId(String id) async {
    pairedDeviceId = id;
    await prefs.setString('pairedDeviceId', id);
    notifyListeners();
  }

  Future<void> generatePairingCode() async {
    pairingCode = (100000 + Random().nextInt(900000)).toString();
    await prefs.setString('pairingCode', pairingCode!);
    notifyListeners();
  }

  Future<bool> completePairing(String code) async {
    if (code == pairingCode) {
      await setPairedDeviceId("PARENT-$deviceId");
      return true;
    }
    return false;
  }

  // ------------------- Parent settings -------------------
  Future<void> setParentPin(String pin) async {
    parentPin = pin;
    await prefs.setString('parentPin', pin);
    notifyListeners();
  }

  Future<void> setDailyLimit(int minutes) async {
    dailyLimitMinutes = minutes;
    await prefs.setInt('dailyLimitMinutes', minutes);
    notifyListeners();
  }

  Future<void> addUsedMinutes(int minutes) async {
    usedMinutesToday += minutes;
    await prefs.setInt('usedMinutesToday', usedMinutesToday);
    notifyListeners();
  }

  Future<void> resetUsage() async {
    usedMinutesToday = 0;
    await prefs.setInt('usedMinutesToday', usedMinutesToday);
    notifyListeners();
  }

  void startAutoTimer() {
    _tick?.cancel();
    lastTick = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      final delta = now.difference(lastTick).inSeconds;
      lastTick = now;
      addUsedMinutes((delta / 60).round());
    });
  }

  void stopAutoTimer() {
    _tick?.cancel();
    _tick = null;
  }

  bool isLimitReached() => usedMinutesToday >= dailyLimitMinutes;

  // ------------------- Link Checker -------------------
  Future<void> addLinkCheck(String url, String status) async {
    final entry = LinkCheckEntry(url: url, status: status, timestamp: DateTime.now());
    linkHistory.insert(0, entry);
    await _saveLinkHistory();
    notifyListeners();
  }

  Future<void> _saveLinkHistory() async {
    final encoded = linkHistory.map((e) => e.encode()).toList();
    await prefs.setStringList('linkHistory', encoded);
  }

  void _loadLinkHistory() {
    final encoded = prefs.getStringList('linkHistory') ?? [];
    linkHistory = encoded.map((s) => LinkCheckEntry.fromJson(s)).toList();
  }

  // ------------------- Blocked sites -------------------
  Future<void> _loadBlockedSites() async {
    blockedSites = prefs.getStringList('blockedSites') ?? [];
    notifyListeners();
  }

  Future<void> _saveBlockedSites() async {
    await prefs.setStringList('blockedSites', blockedSites);
  }

  Future<void> addBlockedSite(String host) async {
    final h = _extractDomain(host.trim().toLowerCase());
    if (h.isEmpty) return;
    if (!blockedSites.contains(h)) {
      blockedSites.add(h);
      await _saveBlockedSites();
      notifyListeners();
    }
  }

  Future<void> removeBlockedSite(String host) async {
    blockedSites.remove(host);
    await _saveBlockedSites();
    notifyListeners();
  }

  // ------------------- Improved domain extraction & blocking -------------------
  // This improved method extracts the base domain (example.com) from many variants,
  // and the isUrlBlocked method blocks subdomains.
  String _extractDomain(String url) {
    try {
      if (!url.startsWith('http')) {
        url = 'https://$url';
      }
      final uri = Uri.parse(url);
      final hostParts = uri.host.split('.');
      // Handle common public suffix pairs like co.uk (this is simple heuristic).
      final tldExceptions = ['co.uk', 'org.uk', 'gov.uk', 'ac.uk'];
      if (hostParts.length >= 3) {
        final lastTwo = '${hostParts[hostParts.length - 2]}.${hostParts.last}';
        if (tldExceptions.contains(lastTwo)) {
          // return last three parts for these exceptions
          return '${hostParts[hostParts.length - 3]}.$lastTwo';
        }
      }
      if (hostParts.length >= 2) {
        return '${hostParts[hostParts.length - 2]}.${hostParts.last}';
      }
      return uri.host;
    } catch (e) {
      final regex = RegExp(r'^(?:https?:\/\/)?(?:[^@\n]+@)?(?:www\.)?([^:\/\n?]+)');
      final match = regex.firstMatch(url);
      if (match != null) {
        final hostParts = match.group(1)!.split('.');
        if (hostParts.length >= 3) {
          final lastTwo = '${hostParts[hostParts.length - 2]}.${hostParts.last}';
          final tldExceptions = ['co.uk', 'org.uk', 'gov.uk', 'ac.uk'];
          if (tldExceptions.contains(lastTwo)) {
            return '${hostParts[hostParts.length - 3]}.$lastTwo';
          }
        }
        if (hostParts.length >= 2) {
          return '${hostParts[hostParts.length - 2]}.${hostParts.last}';
        }
        return match.group(1)!;
      }
      return url;
    }
  }

  bool isUrlBlocked(String url) {
    final domain = _extractDomain(url.toLowerCase());
    return blockedSites.any((blocked) =>
        domain == blocked.toLowerCase() || domain.endsWith('.${blocked.toLowerCase()}'));
  }
}

// ------------------- LinkCheckEntry -------------------
class LinkCheckEntry {
  final String url;
  final String status;
  final DateTime timestamp;

  LinkCheckEntry({required this.url, required this.status, required this.timestamp});

  String encode() => '$url|$status|${timestamp.toIso8601String()}';

  factory LinkCheckEntry.fromJson(String jsonStr) {
    final parts = jsonStr.split('|');
    return LinkCheckEntry(
      url: parts[0],
      status: parts[1],
      timestamp: DateTime.parse(parts[2]),
    );
  }
}

// ------------------- Safe WebView -------------------
class SafeWebView extends StatefulWidget {
  const SafeWebView({super.key});

  @override
  State<SafeWebView> createState() => _SafeWebViewState();
}

class _SafeWebViewState extends State<SafeWebView> {
  late final WebViewController controller;
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (int progress) {
          setState(() {
            _isLoading = progress < 100;
          });
        },
        onPageStarted: (String url) {
          _urlController.text = url;
        },
        onPageFinished: (String url) {
          _urlController.text = url;
          setState(() {
            _isLoading = false;
          });
        },
        onNavigationRequest: (NavigationRequest request) {
          final app = Provider.of<AppState>(context, listen: false);
          final url = request.url.toLowerCase();

          if (app.isUrlBlocked(url)) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('BLOCKED: $url'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onUrlChange: (UrlChange change) {
          _urlController.text = change.url ?? '';
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
  }

  void _loadUrl(String url) {
    final app = Provider.of<AppState>(context, listen: false);

    if (app.isUrlBlocked(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('BLOCKED: $url'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (!url.startsWith('http')) {
      url = 'https://$url';
    }

    controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safe Browser'),
        actions: [
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => controller.loadRequest(Uri.parse('https://www.google.com')),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          // URL Bar
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      hintText: 'Enter URL or search...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onSubmitted: _loadUrl,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _loadUrl(_urlController.text),
                  child: const Text('GO'),
                ),
              ],
            ),
          ),
          // Loading indicator
          if (_isLoading) const LinearProgressIndicator(),
          // WebView
          Expanded(
            child: WebViewWidget(controller: controller),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}

// ------------------- LandingPage -------------------
class LandingPage extends StatelessWidget {
  const LandingPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Protectra')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Choose mode', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontStyle: FontStyle.italic)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.person),
              label: const Text('Parent'),
              onPressed: () {
                if (app.pairedDeviceId == null) {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ParentPairingScreen()));
                } else {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ParentAuth()));
                }
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.child_care),
              label: const Text('Child'),
              onPressed: () {
                if (app.pairedDeviceId == null) {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ChildPairingScreen()));
                } else {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ChildScreen()));
                }
              },
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () async {
                const url = 'https://developer.android.com/work/managed-profiles';
                if (await canLaunchUrl(Uri.parse(url))) {
                  await launchUrl(Uri.parse(url));
                }
              },
              child: const Text('Learn about real device management (Android)'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Note: Website blocking works in the Safe Browser. For system-wide blocking, additional device management is required.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------- ParentAuth -------------------
class ParentAuth extends StatefulWidget {
  const ParentAuth({super.key});
  @override
  State<ParentAuth> createState() => _ParentAuthState();
}

class _ParentAuthState extends State<ParentAuth> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  bool hasPin = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = Provider.of<AppState>(context, listen: false);
    hasPin = app.parentPin.isNotEmpty;
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Parent Login / Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            if (!hasPin) ...[
              const Text('Set a 10-digit PIN for parent access'),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 10,
              ),
              TextField(
                controller: _confirmController,
                keyboardType: TextInputType.number,
                maxLength: 10,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () async {
                  final p = _pinController.text.trim();
                  final c = _confirmController.text.trim();
                  if (p.length == 10 && p == c) {
                    await app.setParentPin(p);
                    setState(() => hasPin = true);
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('PIN set.')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('PINs do not match or invalid length.')));
                  }
                },
                child: const Text('Save PIN'),
              ),
            ] else ...[
              const Text('Enter your PIN to open parent dashboard'),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 10,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  if (_pinController.text.trim() == app.parentPin) {
                    Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ParentDashboard()));
                  } else {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Wrong PIN')));
                  }
                },
                child: const Text('Open Dashboard'),
              ),
              const SizedBox(height: 12),
              TextButton(
                  onPressed: () async {
                    await app.setParentPin('');
                    setState(() => hasPin = false);
                  },
                  child: const Text('Reset PIN (demo)'))
            ]
          ],
        ),
      ),
    );
  }
}

// ------------------- ParentDashboard -------------------
class ParentDashboard extends StatefulWidget {
  const ParentDashboard({super.key});
  @override
  State<ParentDashboard> createState() => _ParentDashboardState();
}

class _ParentDashboardState extends State<ParentDashboard> {
  final _limitController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final app = Provider.of<AppState>(context, listen: false);
    _limitController.text = app.dailyLimitMinutes.toString();
  }

  @override
  void dispose() {
    _limitController.dispose();
    super.dispose();
  }

  void _openLinkChecker() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LinkCheckerScreen()));
  }

  void _openLinkHistory() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LinkHistoryScreen()));
  }

  void _openBlockedSites() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const BlockedWebsitesScreen()));
  }

  void _testSafeBrowser() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SafeWebView()));
  }

  // Methods to control VPN via MethodChannel
  Future<void> _startVpn() async {
    try {
      await _vpnChannel.invokeMethod('startVpn');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('VPN requested (native service).')));
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to start VPN: ${e.message}')));
    }
  }

  Future<void> _stopVpn() async {
    try {
      await _vpnChannel.invokeMethod('stopVpn');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('VPN stop requested.')));
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to stop VPN: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Parent Dashboard')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Daily limit: ${app.dailyLimitMinutes} minutes'),
            const SizedBox(height: 8),
            Text('Used today: ${app.usedMinutesToday} minutes'),
            const SizedBox(height: 16),
            TextField(
              controller: _limitController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Set daily limit (minutes)'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              ElevatedButton(
                onPressed: () {
                  final minutes =
                      int.tryParse(_limitController.text.trim()) ??
                          app.dailyLimitMinutes;
                  app.setDailyLimit(minutes);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Limit saved.')));
                },
                child: const Text('Save'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () {
                  app.resetUsage();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Usage reset.')));
                },
                child: const Text('Reset usage'),
              ),
            ]),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _openLinkChecker,
              child: const Text('Check a Link'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _openLinkHistory,
              child: const Text('View Link History'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _openBlockedSites,
              child: const Text('Manage Blocked Websites'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _testSafeBrowser,
              child: const Text('Test Safe Browser'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _startVpn,
              child: const Text('Enable System-wide Blocking (VPN)'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _stopVpn,
              child: const Text('Disable VPN'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Website blocking works in the Safe Browser. Add domains like "youtube.com" to block them.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------- BlockedWebsitesScreen -------------------
class BlockedWebsitesScreen extends StatefulWidget {
  const BlockedWebsitesScreen({super.key});
  @override
  State<BlockedWebsitesScreen> createState() => _BlockedWebsitesScreenState();
}

class _BlockedWebsitesScreenState extends State<BlockedWebsitesScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Websites')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text('Add domains to block (example: youtube.com)'),
            const SizedBox(height: 8),
            const Text(
              'Blocked sites will be prevented from loading in the Safe Browser',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: 'example.com',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _add,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: app.blockedSites.isEmpty
                  ? const Center(child: Text('No blocked sites yet.'))
                  : ListView.builder(
                      itemCount: app.blockedSites.length,
                      itemBuilder: (context, idx) {
                        final host = app.blockedSites[idx];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            title: Text(host),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => app.removeBlockedSite(host),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _add() {
    final app = Provider.of<AppState>(context, listen: false);
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    app.addBlockedSite(text);
    _ctrl.clear();
    FocusScope.of(context).unfocus();
  }
}

// ------------------- ChildScreen -------------------
class ChildScreen extends StatefulWidget {
  const ChildScreen({super.key});
  @override
  State<ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<ChildScreen> {
  Timer? _sessionTimer;
  int _sessionSeconds = 0;

  @override
  void initState() {
    super.initState();
    final app = Provider.of<AppState>(context, listen: false);
    app.startAutoTimer();
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _sessionSeconds++);
      if (_sessionSeconds % 60 == 0) {
        app.addUsedMinutes(1);
      }
      if (app.isLimitReached()) {
        _showLimitReachedDialog();
      }
    });
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    final app = Provider.of<AppState>(context, listen: false);
    app.stopAutoTimer();
    super.dispose();
  }

  void _showLimitReachedDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Time limit reached'),
        content: const Text(
            'Your daily time limit has been reached. Please ask a parent to extend your time.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'))
        ],
      ),
    );
  }

  void _openLinkChecker() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LinkCheckerScreen()));
  }

  void _openSafeBrowser() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SafeWebView()));
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    final remaining = (app.dailyLimitMinutes - app.usedMinutesToday)
        .clamp(0, app.dailyLimitMinutes);
    return Scaffold(
      appBar: AppBar(title: const Text('Child Mode')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Session time: ${_formatSeconds(_sessionSeconds)}',
                style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            LinearProgressIndicator(
                value: app.dailyLimitMinutes == 0
                    ? 1
                    : app.usedMinutesToday / app.dailyLimitMinutes,
                backgroundColor: const Color(0xFF9BD3E6),
                color: const Color(0xFF447A9C)),
            const SizedBox(height: 8),
            Text('Used: ${app.usedMinutesToday} / ${app.dailyLimitMinutes} minutes'),
            Text('Remaining: $remaining minutes', 
                style: TextStyle(
                  color: remaining < 10 ? Colors.red : Colors.green,
                  fontWeight: FontWeight.bold
                )),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _openLinkChecker,
              child: const Text('Check a Link'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _openSafeBrowser,
              child: const Text('Open Safe Browser'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Safe Browser will block websites that parents have restricted.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatSeconds(int s) {
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// ------------------- LinkCheckerScreen -------------------
class LinkCheckerScreen extends StatefulWidget {
  const LinkCheckerScreen({super.key});
  @override
  State<LinkCheckerScreen> createState() => _LinkCheckerScreenState();
}

class _LinkCheckerScreenState extends State<LinkCheckerScreen> {
  final _urlController = TextEditingController();
  String? _status;
  bool _checking = false;

  Future<void> _checkLink() async {
    final app = Provider.of<AppState>(context, listen: false);
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _checking = true;
      _status = null;
    });

    await Future.delayed(const Duration(seconds: 1));
    
    String status;
    
    // Real blocking logic - check if URL is in blocked list
    if (app.isUrlBlocked(url)) {
      status = 'blocked';
    } else if (url.contains('malware') || url.contains('phish') || url.contains('virus')) {
      status = 'dangerous';
      // Auto-block dangerous sites
      await app.addBlockedSite(url);
    } else if (url.contains('suspicious') || url.contains('gambling') || url.contains('porn')) {
      status = 'suspicious';
    } else {
      status = 'safe';
    }

    await app.addLinkCheck(url, status);

    setState(() {
      _status = status;
      _checking = false;
    });
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'safe':
        return Colors.green;
      case 'suspicious':
        return Colors.orange;
      case 'dangerous':
        return Colors.red;
      case 'blocked':
        return Colors.red;
      default:
        return Colors.black;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'safe':
        return Icons.check_circle;
      case 'suspicious':
        return Icons.warning;
      case 'dangerous':
        return Icons.dangerous;
      case 'blocked':
        return Icons.block;
      default:
        return Icons.help;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link Checker')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Enter URL to check',
                border: OutlineInputBorder(),
                hintText: 'https://example.com'
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checking ? null : _checkLink,
              child: _checking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Check Link Safety'),
            ),
            const SizedBox(height: 20),
            if (_status != null)
              Card(
                color: _statusColor(_status!).withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(_statusIcon(_status!), color: _statusColor(_status!), size: 40),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _status!.toUpperCase(),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: _statusColor(_status!),
                              ),
                            ),
                            Text(
                              _getStatusMessage(_status!),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _getStatusMessage(String status) {
    switch (status) {
      case 'safe':
        return 'This website appears to be safe for browsing.';
      case 'suspicious':
        return 'This website may contain inappropriate content.';
      case 'dangerous':
        return 'This website has been blocked for security reasons.';
      case 'blocked':
        return 'This website is blocked by parental controls.';
      default:
        return 'Unknown status.';
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}

// ------------------- LinkHistoryScreen -------------------
class LinkHistoryScreen extends StatelessWidget {
  const LinkHistoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Link History')),
      body: app.linkHistory.isEmpty
          ? const Center(child: Text('No link checks yet.'))
          : ListView.builder(
              itemCount: app.linkHistory.length,
              itemBuilder: (context, idx) {
                final e = app.linkHistory[idx];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  child: ListTile(
                    title: Text(e.url),
                    subtitle: Text(e.timestamp.toString().substring(0, 16)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _getStatusColor(e.status),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        e.status.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    leading: Icon(_getStatusIcon(e.status), color: _getStatusColor(e.status)),
                  ),
                );
              },
            ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'safe': return Colors.green;
      case 'suspicious': return Colors.orange;
      case 'dangerous': return Colors.red;
      case 'blocked': return Colors.red;
      default: return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'safe': return Icons.check_circle;
      case 'suspicious': return Icons.warning;
      case 'dangerous': return Icons.dangerous;
      case 'blocked': return Icons.block;
      default: return Icons.help;
    }
  }
}

// ------------------- ParentPairingScreen -------------------
class ParentPairingScreen extends StatelessWidget {
  const ParentPairingScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Parent Pairing')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text('Generate a pairing code for the child device:'),
            const SizedBox(height: 20),
            ElevatedButton(
                onPressed: () async {
                  await app.generatePairingCode();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'Pairing code: ${app.pairingCode ?? 'error'}'))); 
                },
                child: const Text('Generate pairing code')),
            const SizedBox(height: 20),
            if (app.pairingCode != null)
              Card(
                color: Colors.blue[50],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text('Pairing Code:', style: TextStyle(fontSize: 16)),
                      const SizedBox(height: 8),
                      Text(app.pairingCode!,
                          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const Text('Enter this code on the child device'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------- ChildPairingScreen -------------------
class ChildPairingScreen extends StatefulWidget {
  const ChildPairingScreen({super.key});
  @override
  State<ChildPairingScreen> createState() => _ChildPairingScreenState();
}

class _ChildPairingScreenState extends State<ChildPairingScreen> {
  final _codeCtrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Child Pairing')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text('Enter the pairing code from the parent device:'),
            const SizedBox(height: 16),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '000000',
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                final code = _codeCtrl.text.trim();
                if (code.length != 6) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter 6-digit code')));
                  return;
                }
                
                final success = await app.completePairing(code);
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Paired successfully!')));
                  Navigator.pushReplacement(context,
                      MaterialPageRoute(builder: (_) => const ChildScreen()));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid code')));
                }
              },
              child: const Text('Pair Device'),
            ),
          ],
        ),
      ),
    );
  }
}
