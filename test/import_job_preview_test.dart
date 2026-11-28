// 后台导入批预览（2026-11-28）：管理页导入进行中态——离开
// 页面再回来，进度仍在（任务在服务里、与页面解绑）。
// 输出 PNG 到 ~/workspace/xiuxian_cancel_activation_20261128/previews/。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/import_job_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('导入进行中：离开页面再回来仍显示进度', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final tempDir = Directory.systemTemp.createTempSync('import_preview_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final externalDb = '${tempDir.path}/external.db';
    final importedDb = '${tempDir.path}/actress/imported.db';
    Directory('${tempDir.path}/actress').createSync(recursive: true);
    File(externalDb).writeAsStringSync('EXTDB');
    final source = ActressDbSource(
      externalPath: () async => externalDb,
      importedPath: () async => importedDb,
      worksCounter: (_) async => 42,
      isIOS: () => false,
    );
    // 服务里有一个正在跑的任务（进度 42%、已处理 123456 条）。
    final jobService = ImportJobService(
      supportDirectoryProvider: () async => tempDir,
      foreground: NoopImportForegroundBridge(),
    );
    jobService.state.value = const ImportJobState(
      phase: ImportJobPhase.running,
      sourceName: '凡人修仙站点.sql',
      progress: ImportJobProgress(
        kind: 'actress',
        phaseLabel: '正在导入',
        statements: 123456,
        fraction: 0.42,
      ),
    );

    Widget page() => MaterialApp(
      home: RepaintBoundary(
        child: ActressDbManagePage(
          source: source,
          importService: ActressDbImportService(
            source: source,
            dbValidator: (_) async =>
                const ActressDbValidation(ok: true, works: 1),
          ),
          importJobService: jobService,
          onLibraryChanged: () async {},
          magnetLibrariesLoader: () async => const [],
        ),
      ),
    );

    // 整段放进 runAsync 真时间里跑：页面 initState 会触发真实
    // IO（启动识别/状态读取），假时钟下这类 future 不返回、
    // 测试会挂死（与 dual 测试点击链同款口径）。
    await tester.runAsync(() async {
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await tester.pumpWidget(page());
      await settle();
      expect(find.textContaining('已处理 123456 条'), findsOneWidget);
      expect(find.text('导入进行中…'), findsOneWidget);

      // 离开页面（整页销毁）再回来：任务在服务里，进度仍在。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.pumpWidget(page());
      await settle();
      expect(find.textContaining('已处理 123456 条'), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-import-cancel')), findsOneWidget);

      await _savePng(tester, 'preview_import_in_progress.png');
    });
  });
}
