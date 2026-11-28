// 取消激活批 C1–C4 修复测试（2026-11-28）：
// ① 嗅探器：女优身份标记在文件尾、磁力段在前 → 必判女优库
//    （旧实现磁力满 25 条提前定案误判磁力）；纯磁力仍判磁
//    力；站点靠 station_code 认、裸 schema_meta 不算站点。
// ② 磁力合并保全：目标库原有 index_categories/tags 等表与
//    行合并后仍在；staging 独有表按其 DDL 补建并入。
// ③ 护栏：全量女优形态（schema_meta format='actress_
//    library'）走磁力合并被拦下且目标库一字不动。
// ④ 来源层 status：导入槽文件在但探针不过 → 外置兜底生
//    效；导入槽好库时不兜底。describe 去版本化。
// ⑤ 读库层：异常落 ImportDebugLog 定点；未激活文案不再带
//    「需带版本字段」。
//
// 真 SQLite 走 actress_magnet_library_test 的 FFI 假件（本
// 机装不上 sqflite_common_ffi，与既有磁力测试同口径）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';
import 'package:fqapp/services/import_debug_log.dart';
import 'package:fqapp/services/unified_import.dart';

import 'actress_magnet_library_test.dart' show FfiDatabase;

const _standardDdl = <String>[
  'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
  'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
  'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
  'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
  'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
  'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('import_fallback_fix_');
  });

  tearDown(() {
    ImportDebugLog.directoryResolver = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('C1 嗅探器：女优标记在尾、磁力在前', () {
    Future<String> writeSql(String name, String content) async {
      final file = File('${dir.path}/$name');
      await file.writeAsString(content);
      return file.path;
    }

    test('合并形态：≥25 条磁力在前、actress_library 标记在文件尾 → actressSql', () async {
      final buf = StringBuffer()
        ..writeln('PRAGMA foreign_keys=OFF;')
        ..writeln('BEGIN TRANSACTION;')
        ..writeln('CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT);')
        ..writeln(
          "INSERT INTO videos VALUES('aaa-001','标题');",
        );
      // 磁力段：30 条磁力线路（旧实现扫到第 25 条就定磁力）。
      for (var i = 0; i < 30; i++) {
        buf.writeln(
          "INSERT INTO video_play_urls VALUES('aaa-001',"
          "'magnet:?xt=urn:btih:TAIL$i','magnet');",
        );
      }
      // 中段填充（模拟磁力段与尾部标记之间的距离）。
      for (var i = 0; i < 200; i++) {
        buf.writeln("-- filler $i ${'x' * 40}");
      }
      // 文件尾：.dump 形态的 schema_meta 建表＋身份标记行。
      buf
        ..writeln(
          'CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT);',
        )
        ..writeln(
          "INSERT INTO schema_meta VALUES('format','actress_library');",
        )
        ..writeln('COMMIT;');
      final path = await writeSql('merged_tail.sql', buf.toString());
      expect(
        await UnifiedImportSniffer.sniff(path),
        UnifiedImportKind.actressSql,
      );
    });

    test('纯磁力夹具：磁力成片、无女优标记 → magnetSql', () async {
      final buf = StringBuffer()
        ..writeln('CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT);');
      for (var i = 0; i < 30; i++) {
        buf.writeln(
          "INSERT INTO video_play_urls VALUES('m-$i',"
          "'magnet:?xt=urn:btih:PURE$i','magnet');",
        );
      }
      final path = await writeSql('pure_magnet.sql', buf.toString());
      expect(
        await UnifiedImportSniffer.sniff(path),
        UnifiedImportKind.magnetSql,
      );
    });

    test('站点夹具：station_code 在场 → siteLibrary', () async {
      final path = await writeSql('site.sql', '''
CREATE TABLE station_code(site_id TEXT PRIMARY KEY, code_text TEXT);
INSERT INTO stations VALUES('demo','演示站');
''');
      expect(
        await UnifiedImportSniffer.sniff(path),
        UnifiedImportKind.siteLibrary,
      );
    });

    test('裸 schema_meta 不算站点标记：只有它 → unknown', () async {
      final path = await writeSql('meta_only.sql', '''
CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT);
INSERT INTO schema_meta VALUES('format','something_else');
''');
      expect(
        await UnifiedImportSniffer.sniff(path),
        UnifiedImportKind.unknown,
      );
    });

    test('真合并 .sql（存在才跑）：必判 actressSql', () async {
      final real = File(
        '${Directory.current.path}/../../xiuxian_db_merge_magnet_20261128'
        '/out/女优库-磁力合并-20261128.sql',
      );
      if (!real.existsSync()) return;
      expect(
        await UnifiedImportSniffer.sniff(real.path),
        UnifiedImportKind.actressSql,
      );
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('真纯磁力 .sql（存在才跑）：必判 magnetSql', () async {
      final real = File(
        '${Directory.current.path}/../../magnet_sql_convert_20261127'
        '/out/磁力库.sql',
      );
      if (!real.existsSync()) return;
      expect(
        await UnifiedImportSniffer.sniff(real.path),
        UnifiedImportKind.magnetSql,
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('C2 磁力合并保全与护栏（真 SQLite）', () {
    Future<FfiDatabase> newDb(
      String label, {
      bool standard = true,
      List<String> extraDdl = const [],
    }) async {
      final file = File('${dir.path}/$label.db');
      if (file.existsSync()) file.deleteSync();
      final db = await FfiDatabase.open(file.path);
      if (standard) {
        for (final ddl in _standardDdl) {
          await db.execute(ddl);
        }
      }
      for (final ddl in extraDdl) {
        await db.execute(ddl);
      }
      return db;
    }

    Future<int> count(Database db, String sql) async {
      final rows = await db.rawQuery(sql);
      return (rows.first['c'] as num).toInt();
    }

    test('合并后目标库原有附加表与行仍在，共有表并入、独有表补建', () async {
      final target = await newDb('target', extraDdl: [
        'CREATE TABLE index_categories (category_type TEXT, category_name TEXT, video_count INTEGER)',
        'CREATE TABLE tags (tag_name TEXT PRIMARY KEY, video_count INTEGER)',
        'CREATE TABLE video_ranking (vod_id TEXT, rank_no INTEGER)',
      ]);
      await target.insert('videos', {
        'vod_id': 'old-001',
        'title': '原有作品',
        'vod_play_from': 'whos',
      });
      await target.insert('video_play_urls', {
        'vod_id': 'old-001',
        'play_url': 'https://cdn/old-001.m3u8',
        'play_from': 'whos',
      });
      await target.insert('index_categories', {
        'category_type': 'actress',
        'category_name': '甲',
        'video_count': 5,
      });
      await target.insert('tags', {'tag_name': '原有标签', 'video_count': 3});
      await target.insert('video_ranking', {'vod_id': 'old-001', 'rank_no': 1});

      final staging = await newDb('staging', extraDdl: [
        'CREATE TABLE tags (tag_name TEXT PRIMARY KEY, video_count INTEGER)',
        'CREATE TABLE actor_ranking (cate_id TEXT, rank_no INTEGER)',
      ]);
      await staging.insert('videos', {
        'vod_id': 'mag-001',
        'title': '磁力作品',
        'vod_play_from': 'magnet',
      });
      await staging.insert('video_play_urls', {
        'vod_id': 'mag-001',
        'play_url': 'magnet:?xt=urn:btih:KEEP1',
        'play_from': 'magnet',
      });
      await staging.insert('video_category', {
        'vod_id': 'mag-001',
        'main_category': '国产原创',
      });
      await staging.insert('tags', {'tag_name': '磁力标签', 'video_count': 1});
      await staging.insert('actor_ranking', {'cate_id': 'a1', 'rank_no': 7});
      await staging.close();

      final outcome = await const ActressMagnetLibraryStore().mergeStaging(
        target,
        staging.path,
        sourceName: '磁力库.sql',
      );
      expect(outcome.ok, isTrue, reason: outcome.error ?? '');

      // 目标库独有表与行原样保留。
      expect(
        await count(
          target,
          "SELECT COUNT(*) AS c FROM index_categories "
          "WHERE category_name = '甲' AND video_count = 5",
        ),
        1,
      );
      expect(
        await count(target, 'SELECT COUNT(*) AS c FROM video_ranking'),
        1,
      );
      // 共有表 tags：原行在、staging 新行并入。
      final tagNames = {
        for (final row in await target.rawQuery('SELECT tag_name FROM tags'))
          row['tag_name'].toString(),
      };
      expect(tagNames, {'原有标签', '磁力标签'});
      // staging 独有表 actor_ranking：按 staging DDL 补建并带行。
      expect(
        await count(target, 'SELECT COUNT(*) AS c FROM actor_ranking'),
        1,
      );
      // 标准合并与登记不回归。
      expect(
        await count(
          target,
          "SELECT COUNT(*) AS c FROM videos WHERE vod_id = 'mag-001'",
        ),
        1,
      );
      expect(
        await count(target, 'SELECT COUNT(*) AS c FROM magnet_libraries'),
        1,
      );
      await target.close();
    });

    test('全量女优形态走磁力合并被护栏拦下且目标库不动', () async {
      final target = await newDb('guard_target');
      await target.insert('videos', {
        'vod_id': 'old-001',
        'title': '原有作品',
        'vod_play_from': 'whos',
      });
      final staging = await newDb('guard_staging', extraDdl: [
        'CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)',
      ]);
      await staging.insert('schema_meta', {
        'key': 'format',
        'value': 'actress_library',
      });
      await staging.insert('videos', {
        'vod_id': 'full-001',
        'title': '全量库作品',
        'vod_play_from': 'whos',
      });
      await staging.insert('video_play_urls', {
        'vod_id': 'full-001',
        'play_url': 'magnet:?xt=urn:btih:FULL1',
        'play_from': 'magnet',
      });
      await staging.close();

      final outcome = await const ActressMagnetLibraryStore().mergeStaging(
        target,
        staging.path,
        sourceName: '女优库-磁力合并.sql',
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('女优库'));
      // 目标库一字不动：作品仍只有原有那部，登记表都没建。
      expect(await count(target, 'SELECT COUNT(*) AS c FROM videos'), 1);
      final tables = await target.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((row) => row['name'].toString()),
        isNot(contains('magnet_libraries')),
      );
      await target.close();
    });
  });

  group('C3 status 探针化兜底', () {
    ActressDbSource source({
      required String external,
      required String imported,
      required int? Function(String path) works,
    }) {
      return ActressDbSource(
        externalPath: () async => external,
        importedPath: () async => imported,
        worksCounter: (path) async => works(path),
        isIOS: () => false,
      );
    }

    test('导入槽文件在但探针不过、外置好库 → 兜底生效', () async {
      final imported = File('${dir.path}/imported.db')
        ..writeAsBytesSync(List.filled(64, 7)); // 在，但打不开/无作品
      final external = File('${dir.path}/external.db')
        ..writeAsBytesSync(List.filled(64, 9));
      final src = source(
        external: external.path,
        imported: imported.path,
        works: (path) => path == external.path ? 42 : null,
      );
      final status = await src.status();
      expect(status.activated, isFalse);
      expect(status.fallbackActive, isTrue);
      expect(status.effectivePath, external.path);
      expect(status.effectiveSlot, ActressDbSlot.external);
    });

    test('导入槽好库时正常生效、不兜底', () async {
      final imported = File('${dir.path}/imported2.db')
        ..writeAsBytesSync(List.filled(64, 7));
      final external = File('${dir.path}/external2.db')
        ..writeAsBytesSync(List.filled(64, 9));
      final src = source(
        external: external.path,
        imported: imported.path,
        works: (_) => 42,
      );
      final status = await src.status();
      expect(status.activated, isTrue);
      expect(status.fallbackActive, isFalse);
      expect(status.effectivePath, imported.path);
    });

    test('describe 去版本化', () {
      const legacy = ActressDbActivation(origin: 'legacy');
      expect(legacy.describe, '存量库（升级前已在用，继续可用）');
      const imported = ActressDbActivation(
        origin: 'import',
        libraryVersion: '20261128merge',
        formatVersion: '1',
      );
      expect(imported.describe, '已导入');
      expect(imported.describe, isNot(contains('版本')));
      expect(imported.describe, isNot(contains('格式')));
    });
  });

  group('C4 读库层留证与文案', () {
    test('开库异常落定点日志、回中文不可用', () async {
      ImportDebugLog.directoryResolver = () async => dir;
      final fallback = ActressLibraryDbFallback(
        pathResolver: () async => '${dir.path}/broken.db',
        opener: (_) async => throw StateError('测试开库失败'),
      );
      final result = await fallback.handle({'op': 'list'});
      expect(result['ok'], isFalse);
      expect(result['error'], '本地女优库不可用，请重新加载数据库');
      final log = File('${dir.path}/${ImportDebugLog.fileName}');
      expect(log.existsSync(), isTrue);
      final text = log.readAsStringSync();
      expect(text, contains('读库层'));
      expect(text, contains('测试开库失败'));
    });

    test('未激活文案不再带「需带版本字段」', () async {
      final fallback = ActressLibraryDbFallback(
        pathResolver: () async => null,
      );
      final result = await fallback.handle({'op': 'list'});
      expect(result['ok'], isFalse);
      expect(result['error'], contains('还没激活'));
      expect(result['error'], isNot(contains('版本字段')));
    });
  });
}
