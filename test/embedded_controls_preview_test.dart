// 内嵌播放器控件九项修法（2026-11-28 用户经火蚁旁支转达令）的
// 改前/改后对照预览：同一夹具、同一状态（已起播、控件可见）各截
// 一张，输出目录由 MOYI_PREVIEW_OUT_DIR 指定，文件名由
// EMBEDDED_CONTROLS_SHOT 指定（before_playing.png / after_playing.png）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/series_detail/film_inline_player.dart';

import 'preview_test_support.dart';
import 'support/controlled_player.dart';

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String path,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('预览：内嵌播放器已起播、控件可见', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 300);
    addTearDown(tester.view.reset);

    final shot =
        Platform.environment['EMBEDDED_CONTROLS_SHOT'] ?? 'after_playing.png';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RepaintBoundary(
            key: const ValueKey<String>('embedded-controls-preview'),
            child: FilmInlinePlayer(
              seriesId: 'film-1',
              title: '抽象三国第一季',
              coverUrl: '',
              episodes: [
                Chapter(itemId: 'e1', title: '第1集', volumeName: ''),
                Chapter(itemId: 'e2', title: '第2集', volumeName: ''),
              ],
              episodeIndex: 0,
              contentLoader: (itemId, tab) async => {
                'video_url': 'https://example.invalid/$itemId.mp4',
              },
              playerFactory: () => ControlledNativePlayer(),
              onBack: () {},
              onFullscreen: () {},
              onOpenEpisodes: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 点海报播放钮起播，等会话建好播放器、首帧与控件都稳定。
    await tester.tap(find.byKey(const ValueKey('film-inline-play')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('film-inline-player')), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('embedded-controls-preview'),
      previewOutPath(shot),
    );
  });
}
