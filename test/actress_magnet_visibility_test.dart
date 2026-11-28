// 「磁力随作品可见」验收测试（2026-11-28 用户验收线）：
// - 作品详情页：番号在库里挂有磁力就必须有磁力区，不管从
//   演员库本地列表、在线源卡片（按番号反查）哪个入口进来；
// - 演员作品列表：带磁力的作品卡上有 115 三态徽标，没磁力
//   的不上标；
// - 片库详情页：补全链把磁力当补全项，查到就出磁力区；
// - 管理页：磁力不再单列区块，状态随数据库一行带出；
// - 查询层：磁力成员判定在「现行导入槽（带登记表）」与
//   「合并库（无登记表、磁力只在播放地址里）」两种库形态下
//   都成立——用真 SQLite 文件 + 真 SQL 跑（FFI 直连
//   libsqlite3，与磁力移植测试同法），不许假查询糊弄谓词。
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hive_ce/hive.dart';

import 'package:fqapp/actress/actress_adapter_http.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_db_manage_page.dart';
import 'package:fqapp/actress/actress_db_source.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';
import 'package:fqapp/actress/actress_magnet_state.dart';
import 'package:fqapp/actress/actress_online_parse.dart';
import 'package:fqapp/actress/actress_online_sources.dart';
import 'package:fqapp/actress/actress_work_detail_page.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart'
    show CloudDirectLink;
import 'package:fqapp/cloud_drive/drive_code_play.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/film_detail_fill.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _PrepareNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Int32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PrepareDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _BindTextNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _BindTextDart =
    int Function(Pointer<Void>, int, Pointer<Utf8>, int, Pointer<Void>);
typedef _BindIntNative = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindIntDart = int Function(Pointer<Void>, int, int);
typedef _BindDoubleNative = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);
typedef _BindNullNative = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);
typedef _BindBlobNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Int32, Pointer<Void>);
typedef _BindBlobDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);
typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ParamCountNative = Int32 Function(Pointer<Void>);
typedef _ParamCountDart = int Function(Pointer<Void>);
typedef _ColCountNative = Int32 Function(Pointer<Void>);
typedef _ColCountDart = int Function(Pointer<Void>);
typedef _ColNameNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColNameDart = Pointer<Utf8> Function(Pointer<Void>, int);
typedef _ColTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColTypeDart = int Function(Pointer<Void>, int);
typedef _ColIntNative = Int64 Function(Pointer<Void>, Int32);
typedef _ColIntDart = int Function(Pointer<Void>, int);
typedef _ColDoubleNative = Double Function(Pointer<Void>, Int32);
typedef _ColDoubleDart = double Function(Pointer<Void>, int);
typedef _ColTextNative = Pointer<Uint8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Uint8> Function(Pointer<Void>, int);
typedef _ColBlobNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _ColBlobDart = Pointer<Void> Function(Pointer<Void>, int);
typedef _ColBytesNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColBytesDart = int Function(Pointer<Void>, int);
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _ChangesNative = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);
typedef _LastRowidNative = Int64 Function(Pointer<Void>);
typedef _LastRowidDart = int Function(Pointer<Void>);

class _Sqlite {
  _Sqlite._() {
    final lib = DynamicLibrary.open('libsqlite3.so.0');
    open = lib.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open');
    close = lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close');
    prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>(
      'sqlite3_prepare_v2',
    );
    bindText = lib.lookupFunction<_BindTextNative, _BindTextDart>(
      'sqlite3_bind_text',
    );
    bindInt = lib.lookupFunction<_BindIntNative, _BindIntDart>(
      'sqlite3_bind_int64',
    );
    bindDouble = lib.lookupFunction<_BindDoubleNative, _BindDoubleDart>(
      'sqlite3_bind_double',
    );
    bindNull = lib.lookupFunction<_BindNullNative, _BindNullDart>(
      'sqlite3_bind_null',
    );
    bindBlob = lib.lookupFunction<_BindBlobNative, _BindBlobDart>(
      'sqlite3_bind_blob',
    );
    step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step');
    finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
      'sqlite3_finalize',
    );
    paramCount = lib.lookupFunction<_ParamCountNative, _ParamCountDart>(
      'sqlite3_bind_parameter_count',
    );
    colCount = lib.lookupFunction<_ColCountNative, _ColCountDart>(
      'sqlite3_column_count',
    );
    colName = lib.lookupFunction<_ColNameNative, _ColNameDart>(
      'sqlite3_column_name',
    );
    colType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>(
      'sqlite3_column_type',
    );
    colInt = lib.lookupFunction<_ColIntNative, _ColIntDart>(
      'sqlite3_column_int64',
    );
    colDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>(
      'sqlite3_column_double',
    );
    colText = lib.lookupFunction<_ColTextNative, _ColTextDart>(
      'sqlite3_column_text',
    );
    colBlob = lib.lookupFunction<_ColBlobNative, _ColBlobDart>(
      'sqlite3_column_blob',
    );
    colBytes = lib.lookupFunction<_ColBytesNative, _ColBytesDart>(
      'sqlite3_column_bytes',
    );
    errmsg = lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg');
    changes = lib.lookupFunction<_ChangesNative, _ChangesDart>(
      'sqlite3_changes',
    );
    lastRowid = lib.lookupFunction<_LastRowidNative, _LastRowidDart>(
      'sqlite3_last_insert_rowid',
    );
  }

  static final instance = _Sqlite._();

  late final _OpenDart open;
  late final _CloseDart close;
  late final _PrepareDart prepare;
  late final _BindTextDart bindText;
  late final _BindIntDart bindInt;
  late final _BindDoubleDart bindDouble;
  late final _BindNullDart bindNull;
  late final _BindBlobDart bindBlob;
  late final _StepDart step;
  late final _FinalizeDart finalize;
  late final _ParamCountDart paramCount;
  late final _ColCountDart colCount;
  late final _ColNameDart colName;
  late final _ColTypeDart colType;
  late final _ColIntDart colInt;
  late final _ColDoubleDart colDouble;
  late final _ColTextDart colText;
  late final _ColBlobDart colBlob;
  late final _ColBytesDart colBytes;
  late final _ErrmsgDart errmsg;
  late final _ChangesDart changes;
  late final _LastRowidDart lastRowid;
}


const _sqliteRow = 100;
const _sqliteDone = 101;

/// 真 SQLite 文件上的裸查询引擎（测试专用）：给
/// ActressLibraryDbFallback 当 opener 用，SQL 全是真跑。
class _RawDb {
  _RawDb._(this._handle);

  final Pointer<Void> _handle;
  var _closed = false;

  static _RawDb openFile(String path) {
    final s = _Sqlite.instance;
    final namePtr = path.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final rc = s.open(namePtr, out);
      if (rc != 0) throw StateError('sqlite3_open 失败 rc=$rc');
      return _RawDb._(out.value);
    } finally {
      calloc.free(namePtr);
      calloc.free(out);
    }
  }

  String get _errorMessage => _Sqlite.instance.errmsg(_handle).toDartString();

  final _pendingFree = <Pointer<Utf8>>[];

  void _flushPendingFree() {
    for (final ptr in _pendingFree) {
      calloc.free(ptr);
    }
    _pendingFree.clear();
  }

  void _bind(Pointer<Void> stmt, int index, Object? value) {
    final s = _Sqlite.instance;
    if (value == null) {
      s.bindNull(stmt, index);
    } else if (value is int) {
      s.bindInt(stmt, index, value);
    } else if (value is bool) {
      s.bindInt(stmt, index, value ? 1 : 0);
    } else if (value is double) {
      s.bindDouble(stmt, index, value);
    } else if (value is Uint8List) {
      final ptr = calloc<Uint8>(value.isEmpty ? 1 : value.length);
      ptr.asTypedList(value.length).setAll(0, value);
      s.bindBlob(stmt, index, ptr.cast<Void>(), value.length, nullptr);
    } else {
      final ptr = value.toString().toNativeUtf8();
      s.bindText(stmt, index, ptr, -1, nullptr);
      _pendingFree.add(ptr);
    }
  }

  List<Map<String, Object?>> _run(String sql, [List<Object?>? arguments]) {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    final stmtOut = calloc<Pointer<Void>>();
    late final Pointer<Void> stmt;
    try {
      final rc = s.prepare(_handle, sqlPtr, -1, stmtOut, nullptr);
      if (rc != 0) {
        throw StateError('SQL 失败：$_errorMessage ← $sql');
      }
      stmt = stmtOut.value;
      final args = arguments ?? const [];
      for (var i = 0; i < args.length; i++) {
        _bind(stmt, i + 1, args[i]);
      }
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtOut);
    }
    try {
      final rows = <Map<String, Object?>>[];
      while (true) {
        final rc = s.step(stmt);
        if (rc == _sqliteRow) {
          final row = <String, Object?>{};
          final n = s.colCount(stmt);
          for (var i = 0; i < n; i++) {
            row[s.colName(stmt, i).toDartString()] = _column(stmt, i);
          }
          rows.add(row);
        } else if (rc == _sqliteDone) {
          break;
        } else {
          throw StateError('SQL 失败：$_errorMessage ← $sql');
        }
      }
      return rows;
    } finally {
      s.finalize(stmt);
      _flushPendingFree();
    }
  }

  Object? _column(Pointer<Void> stmt, int i) {
    final s = _Sqlite.instance;
    switch (s.colType(stmt, i)) {
      case 1:
        return s.colInt(stmt, i);
      case 2:
        return s.colDouble(stmt, i);
      case 3:
        final ptr = s.colText(stmt, i);
        if (ptr == nullptr) return '';
        return ptr.cast<Utf8>().toDartString(length: s.colBytes(stmt, i));
      case 4:
        final bytes = s.colBytes(stmt, i);
        final ptr = s.colBlob(stmt, i);
        if (ptr == nullptr || bytes == 0) return Uint8List(0);
        return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(bytes));
      default:
        return null;
    }
  }

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? arguments,
  ]) async => _run(sql, arguments);

  void exec(String sql) => _run(sql);

  void close() {
    if (_closed) return;
    _closed = true;
    _Sqlite.instance.close(_handle);
  }
}

// ---------------------------------------------------------------------------
// 数据集：三部作品——ssis-001（m3u8 + 2 条磁力，演员甲）、
// mida-002（只有 1 条磁力，演员甲）、ipx-003（只有 m3u8、
// 无磁力，演员乙）。两种库形态：
// - mergedWorld=false：现行导入槽（带磁力登记表，ssis/mida
//   登记在「中文字幕」分类库里）；
// - mergedWorld=true：合并库（没有登记表，磁力只存在于播放
//   地址、分类只在 video_category）。
// ---------------------------------------------------------------------------

const _magnetA1 = 'magnet:?xt=urn:btih:AAAA0001&dn=SSIS-001';
const _magnetA2 = 'magnet:?xt=urn:btih:AAAA0002&dn=SSIS-001-4K';
const _magnetB1 = 'magnet:?xt=urn:btih:BBBB0001&dn=MIDA-002';

({_RawDb db, String path}) _buildDb(
  Directory dir, {
  required bool mergedWorld,
}) {
  final path = '${dir.path}/${mergedWorld ? 'merged' : 'slotted'}.db';
  final db = _RawDb.openFile(path);
  db.exec('CREATE TABLE videos ('
      'vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, '
      'm3u8_url TEXT, vod_play_url TEXT, vod_pubdate TEXT, '
      'type_name TEXT, content TEXT)');
  db.exec('CREATE TABLE video_play_urls ('
      'vod_id TEXT, play_url TEXT, play_from TEXT)');
  db.exec('CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, '
      'name TEXT, avatar TEXT)');
  db.exec('CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT)');
  db.exec('CREATE TABLE video_category (vod_id TEXT, '
      'main_category TEXT)');
  db.exec('CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT)');
  db.exec('CREATE TABLE video_ranking (vod_id TEXT, rank_no INTEGER)');
  db.exec('CREATE TABLE index_categories (category_type TEXT, '
      'category_name TEXT, video_count INTEGER)');
  if (!mergedWorld) {
    db.exec('CREATE TABLE magnet_libraries ('
        'id INTEGER PRIMARY KEY, name TEXT, category TEXT, '
        'source_name TEXT, imported_at INTEGER, works INTEGER, '
        'play_urls INTEGER)');
    db.exec('CREATE TABLE magnet_library_works ('
        'library_id INTEGER, vod_id TEXT)');
    db.exec("INSERT INTO magnet_libraries VALUES "
        "(1, '中文字幕', '中文字幕', '磁力库.sql', 1764331200000, "
        '2, 3)');
    db.exec("INSERT INTO magnet_library_works VALUES "
        "(1, 'ssis-001'), (1, 'mida-002')");
  }
  void video(String id, String title, String date, String type) {
    db.exec("INSERT INTO videos VALUES ('$id', '$title', "
        "'https://img.test/$id.jpg', '', '', '$date', '$type', "
        "'$title 的简介。')");
  }

  void url(String id, String playUrl, String from) {
    db.exec("INSERT INTO video_play_urls VALUES "
        "('$id', '$playUrl', '$from')");
  }

  video('ssis-001', 'SSIS-001 海边物语', '2024-03-01', '剧情');
  url('ssis-001', 'https://v.test/ssis.m3u8', '');
  url('ssis-001', _magnetA1, 'magnet');
  url('ssis-001', _magnetA2, 'magnet');
  video('mida-002', 'MIDA-002 都会夜话', '2024-02-01', '剧情');
  url('mida-002', _magnetB1, 'magnet');
  video('ipx-003', 'IPX-003 青春日记', '2024-01-01', '青春');
  url('ipx-003', 'https://v.test/ipx.m3u8', '');
  db.exec("INSERT INTO actresses VALUES "
      "('a1', '演员甲', 'https://img.test/a1.jpg'), "
      "('a2', '演员乙', 'https://img.test/a2.jpg')");
  db.exec("INSERT INTO video_actress VALUES ('ssis-001', 'a1'), "
      "('mida-002', 'a1'), ('ipx-003', 'a2')");
  db.exec("INSERT INTO index_categories VALUES "
      "('actress', '演员甲', 2), ('actress', '演员乙', 1)");
  db.exec("INSERT INTO video_category VALUES ('ssis-001', '中文字幕'), "
      "('mida-002', '中文字幕'), ('ipx-003', '巨乳美乳')");
  return (db: db, path: path);
}

ActressLibraryDbFallback _fallbackFor(_RawDb db, String path) {
  return ActressLibraryDbFallback(
    pathResolver: () async => path,
    opener: (_) async => db.query,
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 120,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!ready()) {
    throw StateError('等待超时：目标状态一直没出现');
  }
}

void main() {
  group('查询层（真 SQLite）：磁力成员判定两种库形态都成立', () {
    for (final mergedWorld in [false, true]) {
      group(mergedWorld ? '合并库（无登记表）' : '现行导入槽（带登记表）', () {
        late Directory dir;
        late _RawDb db;
        late ActressLibraryDbFallback fallback;

        setUp(() {
          dir = Directory.systemTemp.createTempSync('magnet_vis_');
          final built = _buildDb(dir, mergedWorld: mergedWorld);
          db = built.db;
          fallback = _fallbackFor(db, built.path);
        });
        tearDown(() {
          db.close();
          dir.deleteSync(recursive: true);
        });

        test('detail：磁力全量带出（2 条不被线路上限吃掉）', () async {
          final res = await fallback.handle({
            'op': 'detail',
            'vodId': 'ssis-001',
          });
          expect(res['ok'], isTrue);
          final item = res['item'] as Map;
          expect(item['magnetUrls'], [_magnetA1, _magnetA2]);
          final noMagnet = await fallback.handle({
            'op': 'detail',
            'vodId': 'ipx-003',
          });
          expect(
            (noMagnet['item'] as Map)['magnetUrls'],
            isEmpty,
            reason: '库里没有的番号不许编出磁力',
          );
        });

        test('magnetWorks 全部：只出带磁力的两部、总数对', () async {
          final res = await fallback.handle({
            'op': 'magnetWorks',
            'page': 1,
            'limit': 24,
          });
          expect(res['ok'], isTrue);
          expect(res['total'], 2);
          final ids = [
            for (final row in (res['items'] as List))
              (row as Map)['vodId'],
          ];
          expect(ids, ['ssis-001', 'mida-002']);
        });

        test('magnetWorks 分页：limit 1 两页拼齐、总数不变', () async {
          final p1 = await fallback.handle({
            'op': 'magnetWorks',
            'page': 1,
            'limit': 1,
          });
          final p2 = await fallback.handle({
            'op': 'magnetWorks',
            'page': 2,
            'limit': 1,
          });
          expect(p1['total'], 2);
          expect((p1['items'] as List).single['vodId'], 'ssis-001');
          expect((p2['items'] as List).single['vodId'], 'mida-002');
        });

        test('magnetWorks 分类与搜索：无磁力作品不许混进来', () async {
          final byCategory = await fallback.handle({
            'op': 'magnetWorks',
            'category': '中文字幕',
            'page': 1,
            'limit': 24,
          });
          expect(byCategory['total'], 2);
          final emptyCategory = await fallback.handle({
            'op': 'magnetWorks',
            'category': '巨乳美乳',
            'page': 1,
            'limit': 24,
          });
          expect(
            emptyCategory['total'],
            0,
            reason: 'ipx-003 在这个分类但没磁力，不许出现',
          );
          final byTitle = await fallback.handle({
            'op': 'magnetWorks',
            'q': '都会',
            'page': 1,
            'limit': 24,
          });
          expect(
            [(byTitle['items'] as List).single['vodId']],
            ['mida-002'],
          );
          final noMagnetHit = await fallback.handle({
            'op': 'magnetWorks',
            'q': 'IPX',
            'page': 1,
            'limit': 24,
          });
          expect(noMagnetHit['total'], 0);
        });

        test('magnetCategories：中文字幕 2 部，口径两种形态一致', () async {
          final res = await fallback.handle({'op': 'magnetCategories'});
          expect(res['ok'], isTrue);
          final items = [
            for (final row in (res['categories'] as List))
              Map<String, dynamic>.from(row as Map),
          ];
          expect(items, hasLength(1));
          expect(items.single['name'], '中文字幕');
          expect(items.single['count'], 2);
        });

        test('magnetUrls 批量：只回带磁力的作品、全量', () async {
          final res = await fallback.handle({
            'op': 'magnetUrls',
            'vodIds': ['ssis-001', 'mida-002', 'ipx-003'],
          });
          final urls = res['urls'] as Map;
          expect(urls.keys.toSet(), {'ssis-001', 'mida-002'});
          expect(urls['ssis-001'], [_magnetA1, _magnetA2]);
          expect(urls['mida-002'], [_magnetB1]);
        });
      });
    }
  });

  group('补全服务：磁力是补全项之一', () {
    test('fillFilmDetailByCode 从库 detail 带回磁力（去重保序）', () async {
      Future<Map<String, dynamic>> handle(
        Map<String, dynamic> request,
      ) async {
        switch (request['op']) {
          case 'sameCode':
            return {'ok': true, 'content': '', 'avatars': const []};
          case 'search':
            return {
              'ok': true,
              'items': [
                {'vodId': 'ssis-001'},
              ],
            };
          case 'detail':
            return {
              'ok': true,
              'item': {
                'content': '简介',
                'pic': '',
                'date': '',
                'tags': const <String>[],
                'magnetUrls': [_magnetA1, _magnetA2, _magnetA1],
              },
            };
        }
        return {'ok': false};
      }

      final fill = await fillFilmDetailByCode(
        code: 'SSIS-001',
        javdbClient: JavdbApiClient(fetch: (url) async => ''),
        dbHandle: handle,
      );
      expect(fill.magnets, [_magnetA1, _magnetA2]);
      expect(fill.isEmpty, isFalse);
    });

    test('库里没有这个番号：磁力为空、不编造', () async {
      Future<Map<String, dynamic>> handle(
        Map<String, dynamic> request,
      ) async {
        if (request['op'] == 'search') {
          return {'ok': true, 'items': const []};
        }
        if (request['op'] == 'sameCode') {
          return {'ok': true, 'content': '', 'avatars': const []};
        }
        return {'ok': false};
      }

      final fill = await fillFilmDetailByCode(
        code: 'NOPE-999',
        javdbClient: JavdbApiClient(fetch: (url) async => ''),
        dbHandle: handle,
      );
      expect(fill.magnets, isEmpty);
    });
  });

  group('界面验收：磁力随作品可见', () {
    late Directory hiveDir;

    setUpAll(() async {
      hiveDir = await Directory.systemTemp.createTemp('magnet_vis_hive_');
      Hive.init(hiveDir.path);
      await ShelfStore.instance.init();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall methodCall) async {
              if (methodCall.method == 'getTemporaryDirectory' ||
                  methodCall.method == 'getApplicationSupportDirectory' ||
                  methodCall.method == 'getApplicationDocumentsDirectory') {
                return hiveDir.path;
              }
              return null;
            },
          );
    });
    tearDownAll(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });

    testWidgets('演员库：演员作品卡带磁力徽标、无磁力不上标，点卡进详情有磁力区', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory.systemTemp.createTempSync('magnet_vis_ui_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final built = _buildDb(dir, mergedWorld: true);
      addTearDown(built.db.close);
      final store = LocalStore();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressLibraryNativePage(
            repository: _FakeRepository(),
            store: store,
            fallback: _fallbackFor(built.db, built.path),
            onlineFetch: (url, headers) async => '',
            magnetStateResolver: _emptyResolver(),
          ),
        ),
      );
      // 最新列表三部都在：两部带磁力的卡上有徽标、一部没有。
      await _until(
        tester,
        () => find.text('IPX-003 青春日记').evaluate().isNotEmpty,
      );
      await _until(
        tester,
        () => find.text('115 · 未下载').evaluate().length == 2,
      );
      expect(find.text('115 · 未下载'), findsNWidgets(2));
      // 进演员页签点演员甲：她的两部作品都在且都带徽标。
      await tester.tap(find.text('演员'));
      await _until(
        tester,
        () => find.text('演员甲').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('演员甲').first);
      await _until(
        tester,
        () => find.text('MIDA-002 都会夜话').evaluate().isNotEmpty,
      );
      expect(find.text('115 · 未下载'), findsNWidgets(2));
      // 点带磁力的作品卡进详情：磁力区两条都在、复制钮在。
      await tester.tap(find.text('SSIS-001 海边物语').first);
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('work-detail-db-magnets'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('work-detail-db-magnet-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('work-detail-db-magnet-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('work-detail-db-magnet-copy-0')),
        findsOneWidget,
      );
      expect(find.text('磁力（库内）'), findsOneWidget);
    });

    testWidgets('详情页复制钮：点按复制磁力链接并给中文提示', (tester) async {
      final dir = Directory.systemTemp.createTempSync('magnet_vis_copy_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final built = _buildDb(dir, mergedWorld: true);
      addTearDown(built.db.close);
      final clipboard = _ClipboardCapture()..install();
      addTearDown(clipboard.uninstall);
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressWorkDetailPage.local(
            vodId: 'ssis-001',
            fallback: _fallbackFor(built.db, built.path),
            repository: _FakeRepository(),
            javdbClient: JavdbApiClient(fetch: (url) async => ''),
            probeFetch: _probeOk,
            magnetStateResolver: _emptyResolver(),
            drivePlayFinder: DriveCodePlayFinder(
              isLoggedIn: () async => false,
              search: (keyword) async => const [],
              directLink: (file) async =>
                  const CloudDirectLink(url: 'https://x.test/none.m3u8'),
            ),
            playerFactory: () => ControlledNativePlayer(),
            playUrlPrep: (url, headers) async => url,
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('work-detail-db-magnet-copy-1'))
                .evaluate()
                .isNotEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey('work-detail-db-magnet-copy-1')),
      );
      await _until(tester, () => clipboard.text == _magnetA2);
      expect(clipboard.text, _magnetA2);
      await _until(
        tester,
        () => find.text('磁力链接已复制').evaluate().isNotEmpty,
      );
    });

    testWidgets('在线入口进详情：按番号反查把库内磁力补进磁力区', (tester) async {
      final dir = Directory.systemTemp.createTempSync('magnet_vis_online_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final built = _buildDb(dir, mergedWorld: false);
      addTearDown(built.db.close);
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressWorkDetailPage.online(
            source: const Av123ActressSource(),
            card: const OnlineVideoCard(
              pageUrl: 'https://123av.com/cn/v/ssis-001',
              title: 'SSIS-001 在线标题',
              cover: 'https://img.test/p1.jpg',
            ),
            fallback: _fallbackFor(built.db, built.path),
            repository: _FakeRepository(),
            onlineFetch: _fake123Fetch,
            javdbClient: JavdbApiClient(fetch: (url) async => ''),
            probeFetch: _probeOk,
            magnetStateResolver: _emptyResolver(),
            drivePlayFinder: DriveCodePlayFinder(
              isLoggedIn: () async => false,
              search: (keyword) async => const [],
              directLink: (file) async =>
                  const CloudDirectLink(url: 'https://x.test/none.m3u8'),
            ),
            playerFactory: () => ControlledNativePlayer(),
            playUrlPrep: (url, headers) async => url,
          ),
        ),
      );
      // 在线卡本身不带任何磁力数据：磁力区出现只能是按番号
      // 反查本地库收割来的（本批修复点）。
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('work-detail-db-magnets'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('work-detail-db-magnet-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('work-detail-db-magnet-1')),
        findsOneWidget,
      );
      expect(find.text(_magnetA1), findsOneWidget);
    });

    testWidgets('片库详情：补全带回磁力就出磁力区、点按复制；没有就不出', (
      tester,
    ) async {
      final clipboard = _ClipboardCapture()..install();
      addTearDown(clipboard.uninstall);
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<void> pumpFilm(FilmDetailFill fill) async {
        await tester.pumpWidget(
          hostPage(
            KeyedSubtree(
              key: UniqueKey(),
              child: SeriesDetailPage(
                seriesId: 'ssis-001',
                historyStore: MemoryReaderStore(),
                title: 'SSIS-001 海边物语',
                cover: '',
                episodes: [chapterAt(0), chapterAt(1)],
                seriesLoader: (_) async => SeriesDetail(
                  seriesId: 'ssis-001',
                  title: 'SSIS-001 海边物语',
                  episodeCount: 2,
                  episodeLabel: '共2集',
                  status: 1,
                ),
                siteDetailLoader: (id) async => const FilmSiteDetail(
                  synopsis: '本站简介。',
                  extra: {'play_from': '线路甲'},
                  stills: [],
                ),
                commentLoader: (_) async => const PlayletCommentPage(),
                filmFillLoader: (code, meta) async => fill,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
      }

      await pumpFilm(
        const FilmDetailFill(
          code: 'SSIS-001',
          magnets: [_magnetA1, _magnetA2],
        ),
      );
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('film-detail-db-magnets'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('film-detail-db-magnet-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('film-detail-db-magnet-1')),
        findsOneWidget,
      );
      expect(find.text('磁力链接（女优库）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('film-detail-db-magnet-0')),
      );
      await _until(tester, () => clipboard.text == _magnetA1);
      expect(clipboard.text, _magnetA1);

      // 补全没带磁力（库里没有这个番号）：磁力区不出、不编造。
      await pumpFilm(const FilmDetailFill(code: 'IPX-003'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('film-detail-db-magnets')),
        findsNothing,
      );
    });

    testWidgets('管理页：磁力状态随数据库一行带出、无独立磁力区块', (tester) async {
      final dir = Directory.systemTemp.createTempSync('magnet_vis_manage_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final externalDb = '${dir.path}/external.db';
      final importedDb = '${dir.path}/actress/imported.db';
      Directory('${dir.path}/actress').createSync(recursive: true);
      File(externalDb).writeAsStringSync('EXTDB');
      File(importedDb).writeAsStringSync('IMPDB');
      final source = ActressDbSource(
        externalPath: () async => externalDb,
        importedPath: () async => importedDb,
        worksCounter: (_) async => 42,
        isIOS: () => false,
      );
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDbManagePage(
            source: source,
            onLibraryChanged: () async {},
            magnetLibrariesLoader: () async => const [
              MagnetLibraryRecord(
                id: 1,
                name: '中文字幕',
                category: '中文字幕',
                sourceName: '磁力库.sql',
                importedAtMillis: 1764331200000,
                works: 96364,
                playUrls: 99301,
              ),
            ],
          ),
        ),
      );
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('magnet-merged-status'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.text('磁力已随数据库生效：1 个分类 · 登记作品 96364 部（磁力链接在演员库作品详情里看）'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('magnet-library-section')), findsNothing);
      expect(find.text('磁力分类库'), findsNothing);
    });
  });
}

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('all', '全部'),
    CatalogCategory('new', '最新'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    return CatalogPage([
      Drama(
        id: '$source-1',
        source: source,
        title: '$source 作品一',
        tags: const ['CODE-1'],
      ),
    ], page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {}

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/a.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/a.m3u8');
}

Future<FeedProbeResponse> _probeOk(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  return FeedProbeResponse(
    statusCode: 200,
    headers: const {},
    headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
  );
}

/// 115 侧全空的解析器：有磁力的作品一律「未下载」态。
MagnetDriveStateResolver _emptyResolver() => MagnetDriveStateResolver(
  listTasks: () async => const [],
  submittedHashes: () async => const {},
  confirmInDrive: (_) async => false,
);

Future<String> _fake123Fetch(String url, Map<String, String> headers) async {
  if (url.contains('/stream')) {
    return '{"media":{"stream":"https://cdn.test/ssis-001.m3u8"}}';
  }
  if (url.contains('/cn/v/')) {
    return '<html><body>'
        '<h1>SSIS-001 在线标题</h1>'
        '<div class="preview-images">'
        '<img src="https://img.test/still1.jpg">'
        '</div>'
        '<script>' +
        r'''player(JSON.parse('[{\u0022number\u0022:1,\u0022name\u0022:\u00221\u0022,\u0022url\u0022:\u0022https:\\/\\/embed.test\\/e\\/XYZ1\u0022}]')''' +
        '</script></body></html>';
  }
  return '''
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://img.test/p1.jpg" alt=""></a>
  <div class="card__title">SSIS-001 在线标题</div>
</div>
''';
}

/// 剪贴板捕获：点按复制的断言只认这里截到的文本。
class _ClipboardCapture {
  String? text;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            text = (call.arguments as Map)['text']?.toString();
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }
}
