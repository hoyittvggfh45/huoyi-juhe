// 磁力分类自动登记预览截图：合并库形态的真 FFI 库（31 个主
// 分类 + 无分类磁力作品、无磁力登记表）先跑真的自动补登记，
// 再用读库层打开演员库原生页，截分类栏——32 个磁力分类齐现。
// 输出 PNG 到
// ~/workspace/xiuxian_magnet_category_register_20261128/previews/。
// 跑法：单独跑本文件、--no-pub，不要与功能测试混链。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';
import 'package:fqapp/actress/actress_magnet_state.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_fixtures.dart';
import 'actress_magnet_category_register_test.dart' as reg;
import 'preview_test_support.dart';

const _previewDir =
    '/home/hatch/workspace/xiuxian_magnet_category_register_20261128/previews';
const _coverUrl = 'https://v.hersav.me/images/av/preview-magnet.jpg';
const _sourceFileName = '女优库-磁力合并-20261128.db';
const _fallbackName = '女优库-磁力合并-20261128';

/// 合并库实测的 31 个主分类：前 20 个带磁力作品、后 11 个
/// 只有普通线路（自动登记建空片、计数 0，分类照样齐现）。
const _magnetCategories = [
  '国产原创', '有码', '4K', '高清中字字幕', '欧美无码', '三级写真',
  '动漫原创', 'VR视频区', '素人有码系列', '无码', '韩国主播',
  '亚洲无码原创', '4K原版', '三级', '日本有码', '动漫', '亚洲有码原创',
  '国产', '中文有码', '其他',
];
const _plainCategories = [
  '欧美', '国产自拍', '华语精品', '熟女人妻', '国产精品', '乱伦精品',
  '制服丝袜', '中文无码', '主播网红', '国产色情', '欧美大屌',
];

const _ddl = <String>[
  'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
  'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
  'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
  'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
  'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
];

Future<void> _seedWork(
  Database db,
  String vodId, {
  String? category,
  bool magnet = false,
}) async {
  await db.insert('videos', {
    'vod_id': vodId,
    'title': '$vodId 预览作品',
    'pic_url': _coverUrl,
    'vod_pubdate': '2026-11-28',
    'vod_play_from': magnet ? 'magnet' : 'whos',
    'type_name': '有码',
  });
  if (category != null) {
    await db.insert('video_category', {
      'vod_id': vodId,
      'main_category': category,
    });
  }
  await db.insert('video_play_urls', {
    'vod_id': vodId,
    'play_url': magnet
        ? 'magnet:?xt=urn:btih:PREVIEW$vodId'
        : 'https://cdn/$vodId.m3u8',
    'play_from': magnet ? 'magnet' : 'whos',
  });
}

/// 种一本合并库形态的库并跑真的自动补登记，回库文件。
Future<File> _seedMergedFile(Directory dir) async {
  final file = File('${dir.path}/merged.db');
  final db = await reg.FfiDatabase.open(file.path);
  for (final ddl in _ddl) {
    await db.execute(ddl);
  }
  await db.insert('actresses', {'cate_id': 'a1', 'name': '演员甲', 'sex': '女'});
  var n = 0;
  for (final category in _magnetCategories) {
    n++;
    await _seedWork(db, 'mag-${n}a', category: category, magnet: true);
    await _seedWork(db, 'mag-${n}b', category: category, magnet: true);
  }
  for (final category in _plainCategories) {
    n++;
    await _seedWork(db, 'pln-${n}a', category: category);
  }
  await _seedWork(db, 'unc-001', magnet: true);
  final outcome = await const ActressMagnetLibraryStore()
      .ensureAutoRegistered(db, sourceName: _sourceFileName);
  expect(outcome.changed, isTrue);
  expect(outcome.addedSlices.length, 32);
  await db.close();
  return file;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 25; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late Directory dir;

  setUp(() {
    store = LocalStore();
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('magnet_register_preview_');
  });
  tearDown(() {
    store.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('预览：自动登记后演员库分类栏 32 类齐现', (tester) async {
    final file = await tester.runAsync(() => _seedMergedFile(dir));
    final lib = ActressLibraryDbFallback(
      pathResolver: () async => file!.path,
      opener: (p) async => (await reg.FfiDatabase.open(p)).rawQuery,
    );
    // 数据层先验：分类组恰好 32 类（31 主分类 + 兜底片）。
    final cats = await lib.handle({'op': 'magnetCategories'});
    expect(cats['ok'], isTrue);
    final names = [
      for (final c in (cats['categories'] as List).cast<Map>())
        c['name'].toString(),
    ];
    expect(names.length, 32);
    expect(names, contains(_fallbackName));
    expect(names, contains('欧美')); // 无磁力作品的分类也在（计数 0）

    await loadPreviewFonts(tester);
    final png = await tester.runAsync(
      () => fakeComicPagePng(const Color(0xFF5B3A8E)),
    );
    final sample = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkImage(_coverUrl),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sample!))),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressLibraryNativePage(
              repository: FixtureRepository(),
              store: store,
              fallback: lib,
              magnetStateResolver: MagnetDriveStateResolver(
                listTasks: () async => const <Pan115OfflineTask>[],
                submittedHashes: () async => const <String>{},
                confirmInDrive: (_) async => false,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('native-magnet-group')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('native-magnet-cat-4K原版')),
      findsOneWidget,
    );
    expect(find.text('4K · 2'), findsOneWidget);
    await _savePng(tester, 'preview_category_bar_32.png');
  });
}
