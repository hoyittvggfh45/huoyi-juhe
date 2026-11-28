// 取消激活批预览（2026-11-28）：影视区切换站点弹窗——打包站点
// （sqlManaged+bundled）进内置区直接显示，不再是空的内置区。
// 输出 PNG 到 ~/workspace/xiuxian_cancel_activation_20261128/previews/。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_cancel_activation_20261128/previews';

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
}

SourceEntry _bundled(String id, String name, SourceKind kind) => SourceEntry(
  id: id,
  name: name,
  kind: kind,
  extra: const {
    'builtin': false,
    'sqlManaged': true,
    'bundled': true,
    'contentType': 'video',
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('影视区切换站点：打包站在内置区直接显示', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rows = <SourceEntry>[
      _bundled('sql_gimy', 'Gimy剧迷', SourceKind.pyImport),
      _bundled('sql_dandanzan', '蛋蛋赞', SourceKind.pyImport),
      _bundled('sql_555dy', '555电影', SourceKind.pyImport),
      _bundled('sql_nkdy', '耐看电影', SourceKind.pyImport),
      _bundled('sql_jar_kuaikan', '快看影视', SourceKind.jarImport),
      _bundled('sql_jar_fengye', '枫叶影视', SourceKind.jarImport),
      _bundled('sql_legado_1', '笔趣阁', SourceKind.legadoImport),
      const SourceEntry(
        id: 'user-py',
        name: '用户导入站',
        kind: SourceKind.pyImport,
        extra: {'contentType': 'video'},
      ),
    ];
    final entries = videoZoneSiteEntries(rows, 100000);
    final builtinCount = entries
        .where((e) => e.zone == SiteGridZone.builtin)
        .length;
    expect(builtinCount, greaterThanOrEqualTo(6),
        reason: '打包站应进内置区');

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            child: Scaffold(
              body: SiteGridDialog(
                sites: entries,
                initialZone: SiteGridZone.builtin,
                enablePluginZone: true,
                maxHeight: 1200,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    });
    expect(find.textContaining('内置区'), findsWidgets);
    await _savePng(tester, 'preview_video_zone_bundled_builtin.png');
  });
}
