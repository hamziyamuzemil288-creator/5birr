import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:birr5/core/widgets/map_tile_layer.dart';

// Regression tests for the "App Error Detected" crash: a single failed map
// tile fetch (SocketException "Connection reset by peer") escaped flutter_map's
// tile loading pipeline and was treated as a fatal app-wide error. The shared
// ResilientTileLayer must keep such failures inside the map layer.
void main() {
  // Offline client so widget tests never touch the real OSM tile server.
  // Tiles fail with a 404, which is itself part of the graceful-error path.
  final offlineClient = MockClient((request) async => http.Response('no', 404));

  // Tiles fail with a connection reset — the exact signature from the bug
  // report.
  final resettingClient = MockClient((request) async {
    throw http.ClientException('Connection reset by peer');
  });

  NetworkTileProvider provider(http.BaseClient client) =>
      NetworkTileProvider(silenceExceptions: true, httpClient: client);

  Future<TileLayer> pumpAndGrabLayer(
    WidgetTester tester,
    NetworkTileProvider tileProvider,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: FlutterMap(
            children: [
              ResilientTileLayer(tileProvider: tileProvider),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    return tester.widget<TileLayer>(find.byType(TileLayer));
  }

  testWidgets('ResilientTileLayer configures a resilient TileLayer',
      (WidgetTester tester) async {
    final layer = await pumpAndGrabLayer(tester, provider(offlineClient));

    // Same OSM endpoint the screens used before the shared helper existed.
    expect(layer.urlTemplate, 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
    // Required by the OpenStreetMap tile usage policy: the user agent is
    // forwarded into the provider's request headers.
    expect(layer.tileProvider.headers['User-Agent'],
        contains('com.amistbirr.myapp'));
    // The crash fix: failures must be silenced in the provider AND evicted
    // with a placeholder so the map self-heals instead of erroring out.
    expect(layer.errorImage, isNotNull);
    expect(layer.evictErrorTileStrategy, EvictErrorTileStrategy.dispose);
    expect(layer.errorTileCallback, isNotNull);
  });

  testWidgets('a failing tile fetch never escapes as an unhandled exception',
      (WidgetTester tester) async {
    // Collect uncaught errors the way PlatformDispatcher.onError would; the
    // production app routes these to the fatal "App Error Detected" screen.
    final uncaught = <FlutterErrorDetails>[];
    final originalHandler = FlutterError.onError;
    FlutterError.onError = (details) => uncaught.add(details);
    addTearDown(() => FlutterError.onError = originalHandler);

    await pumpAndGrabLayer(tester, provider(resettingClient));
    // Let tile requests fire and fail.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(uncaught, isEmpty,
        reason: 'a tile failure must never reach the global crash handler');

    // The layer must still be alive and on screen — the map stays usable.
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('placeholder errorImage is a decodable PNG', () async {
    final bytes = placeholderPngBytes();

    // PNG magic number.
    expect(
      bytes.sublist(0, 8),
      equals(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    );

    // Actually decode it — this is what the map does when a tile fails.
    // Plain test (no testWidgets): decoding uses real async I/O, which never
    // completes under the widget tester's FakeAsync clock.
    final stream = MemoryImage(bytes).resolve(const ImageConfiguration());
    final completer = Completer<ImageInfo>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) => completer.isCompleted ? null : completer.complete(info),
      onError: (Object e, StackTrace? s) =>
          completer.isCompleted ? null : completer.completeError(e, s),
    );
    stream.addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      stream.removeListener(listener);
    }
  });
}
