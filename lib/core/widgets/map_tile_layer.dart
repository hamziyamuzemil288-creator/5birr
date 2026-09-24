import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// Shared OpenStreetMap [TileLayer] used by every map in the app.
///
/// Why this exists: with the default [NetworkTileProvider], a single failed
/// tile HTTP request (SocketException "Connection reset by peer",
/// ClientException, HTTP 4xx/5xx, …) is rethrown out of the image loading
/// pipeline and, because tile loads run outside the widget build, it lands in
/// `PlatformDispatcher.onError` — which the app treats as a fatal crash and
/// swaps the whole screen for the "App Error Detected" page. One flaky tile
/// must never take down a map screen.
///
/// This layer makes tile failures graceful:
///  * `errorImage` renders a light placeholder instead of a broken tile.
///  * `errorTileCallback` + [EvictErrorTileStrategy.dispose] evict the failed
///    tile from the image cache so the next pan/zoom re-requests it
///    (self-retry).
///  * failures are logged with `debugPrint` (dev visibility, no user impact).
///  * `silenceExceptions` guarantees a failed fetch resolves to a transparent
///    tile rather than an exception escaping the provider.
///
/// Transport-level resilience (transient resets) is additionally covered by
/// the `RetryClient` flutter_map uses by default.
class ResilientTileLayer extends StatelessWidget {
  final String? urlTemplate;

  /// Optional override (tests inject a failing client here). When null, a
  /// [NetworkTileProvider] with `silenceExceptions: true` is used.
  final TileProvider? tileProvider;

  const ResilientTileLayer({super.key, this.urlTemplate, this.tileProvider});

  static const _defaultUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  Widget build(BuildContext context) {
    return TileLayer(
      urlTemplate: urlTemplate ?? _defaultUrlTemplate,
      // Explicitly resilient provider — TileLayer's default has
      // silenceExceptions: false, which is the crash path being fixed here.
      tileProvider:
          tileProvider ?? NetworkTileProvider(silenceExceptions: true),
      // Android identifies tile requests by the app's package name
      // (OpenStreetMap tile usage policy).
      userAgentPackageName: 'com.amistbirr.myapp',
      // Light placeholder where a tile failed to load, instead of an error.
      errorImage: MemoryImage(_placeholderBytes),
      // Failed tiles are dropped from the image cache so any subsequent
      // pan/zoom re-requests them — the map self-heals without user action.
      evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
      errorTileCallback: (tile, error, stackTrace) {
        debugPrint(
          'ResilientTileLayer: tile ${tile.coordinates} failed '
          '(${error.runtimeType}); will retry on next load',
        );
      },
    );
  }
}

/// 64×64 #ECEFF1 RGBA PNG used as the failed-tile placeholder.
///
/// Embedded as bytes (instead of an asset) so it needs no pubspec entry and
/// works identically in widget tests. Generated with zlib deflateSync.
const _placeholderPng = <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x40, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0xaa, 0x69, 0x71, 0xde, 0x00, 0x00, 0x00, //
  0x98, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0xed, 0xd0, 0xb1, 0x09, 0x00, //
  0x20, 0x10, 0xc0, 0xc0, 0xdf, 0x7f, 0x56, 0x41, 0x9c, 0x40, 0xc7, 0xb8, //
  0xc2, 0x14, 0xd7, 0x87, 0xcc, 0xda, 0xe7, 0xfe, 0x6c, 0x74, 0x80, 0xd6, //
  0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, 0x01, 0x5a, 0x03, //
  0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, //
  0x01, 0x5a, 0x03, 0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, //
  0x68, 0x0d, 0xd0, 0x01, 0x5a, 0x03, 0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, //
  0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, 0x01, 0x5a, 0x03, 0x74, 0x80, 0xd6, //
  0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, 0x01, 0x5a, 0x03, //
  0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, //
  0x01, 0x5a, 0x03, 0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, 0x35, 0x40, 0x07, //
  0x68, 0x0d, 0xd0, 0x01, 0x5a, 0x03, 0x74, 0x80, 0xd6, 0x00, 0x1d, 0xa0, //
  0x35, 0x40, 0x07, 0x68, 0x0d, 0xd0, 0x01, 0xda, 0x03, 0xaa, 0x9a, 0xb3, //
  0x85, 0xb1, 0x87, 0x62, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, //
  0x44, 0xae, 0x42, 0x60, 0x82, //
];

final Uint8List _placeholderBytes = Uint8List.fromList(_placeholderPng);

/// Bytes of the failed-tile placeholder image (exposed for tests).
Uint8List placeholderPngBytes() => Uint8List.fromList(_placeholderPng);
