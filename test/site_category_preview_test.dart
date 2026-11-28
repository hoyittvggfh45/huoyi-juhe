// 内置站自动分类预览（2026-11-28）：影视区切换站点弹窗内置区——
// 打包站不再一堵墙挂在「午夜」组下，而是按分类出段：影视 /
// 成人影视 · Python 站 / 成人影视 · Jar 站 / 成人影视 · 书源站，
// 每段带计数。条目由真实纯函数 videoZoneSiteEntries 从登记行
// （sqlManaged+bundled+isAdult）组出，不手写假条目。
// 输出 PNG 到 ~/workspace/xiuxian_station_list_cats_20261128/previews/。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_station_list_cats_20261128/previews';

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
}

SourceEntry _bundled(
  String id,
  String name,
  SourceKind kind, {
  required bool adult,
}) => SourceEntry(
  id: id,
  name: name,
  kind: kind,
  extra: {
    'builtin': false,
    'sqlManaged': true,
    'bundled': true,
    'contentType': 'video',
    'isAdult': adult,
    if (kind == SourceKind.legadoImport) 'hasExplore': true,
  },
);

Future<void> _pumpDialog(
  WidgetTester tester,
  List<SourceEntry> rows,
) async {
  final entries = videoZoneSiteEntries(rows, 100000);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: SiteGridDialog(
              sites: entries,
              initialZone: SiteGridZone.builtin,
              enablePluginZone: true,
              maxHeight: 1500,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('预览1：内置区分类总览（影视 + 成人影视三组分段带计数）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpDialog(tester, [
      _bundled('sql_gimy', 'Gimy剧迷', SourceKind.pyImport, adult: false),
      _bundled('sql_555dy', '555电影', SourceKind.pyImport, adult: false),
      _bundled('sql_nkdy', '耐看电影', SourceKind.pyImport, adult: false),
      _bundled('sql_91sanji', '🔞91三级', SourceKind.pyImport, adult: true),
      _bundled('sql_aiwu', '🔞AI污', SourceKind.pyImport, adult: true),
      _bundled('sql_hj', '🔞海角', SourceKind.pyImport, adult: true),
      _bundled('sql_missav', '🔞MissAV', SourceKind.jarImport, adult: true),
      _bundled('sql_jable', '🔞Jable', SourceKind.jarImport, adult: true),
      _bundled('sql_supa', '🔞素人', SourceKind.jarImport, adult: true),
      _bundled('sql_legado_a', '🔞午夜书屋', SourceKind.legadoImport, adult: true),
      _bundled('sql_legado_b', '🔞夜色', SourceKind.legadoImport, adult: true),
    ]);

    expect(find.text('影视 3'), findsOneWidget);
    expect(find.text('成人影视 · Python 站 3'), findsOneWidget);
    expect(find.text('成人影视 · Jar 站 3'), findsOneWidget);
    expect(find.text('成人影视 · 书源站 2'), findsOneWidget);
    await _savePng(tester, '01_category_overview.png');
  });

  testWidgets('预览2：类内列表（成人影视 · Jar 站整段）', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpDialog(tester, [
      for (var i = 1; i <= 12; i++)
        _bundled(
          'sql_jar_$i',
          '🔞Jar站$i',
          SourceKind.jarImport,
          adult: true,
        ),
      _bundled('sql_clean', '清净影视', SourceKind.pyImport, adult: false),
    ]);

    expect(find.text('成人影视 · Jar 站 12'), findsOneWidget);
    expect(find.text('影视 1'), findsOneWidget);
    await _savePng(tester, '02_category_inner_list.png');
  });
}
