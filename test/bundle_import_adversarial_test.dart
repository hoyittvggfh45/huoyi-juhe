// Adversarial-delivery end-to-end tests for the bundle import
// chain (2026-11-28 import utf8 fix round 2).
//
// Device fault model (pinpointed on the sister product line):
// the runtime's stream delivery restarts decoder state every
// 30720 bytes, so any consumer that decodes the byte stream with
// a stateful chunk decoder dies when a multi-byte character
// straddles a segment boundary. The production chain must be
// immune by construction (byte-level line splitting). These
// tests drive the REAL production SiteLibraryBundleImporter
// (real staging via FFI sqlite, real verify, real materialize
// SQL shape) over a synthetic three-segment bundle whose text
// payload is crafted so 3-byte characters straddle every 30720
// boundary, delivered two hostile ways:
//   A) re-chunked into exact 30720-byte events;
//   B) re-chunked into pseudo-random 1..65536-byte events.
// A control case feeds the same bytes through the OLD consumer
// shape (independent utf8.decode per 30720 segment) and asserts
// it throws FormatException -- proving the fixture really is
// adversarial and the chain's pass is not vacuous.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/import_debug_log.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/site_library_bundle.dart';
import 'package:fqapp/services/sql_text_stream.dart';

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _ExecNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ExecDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
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
typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
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
typedef _ColTextNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Utf8> Function(Pointer<Void>, int);

class _Sqlite {
  _Sqlite._(DynamicLibrary lib)
    : open = lib.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open'),
      close = lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close'),
      exec = lib.lookupFunction<_ExecNative, _ExecDart>('sqlite3_exec'),
      errmsg = lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg'),
      prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>(
        'sqlite3_prepare_v2',
      ),
      step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step'),
      finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
        'sqlite3_finalize',
      ),
      columnCount = lib.lookupFunction<_ColCountNative, _ColCountDart>(
        'sqlite3_column_count',
      ),
      columnName = lib.lookupFunction<_ColNameNative, _ColNameDart>(
        'sqlite3_column_name',
      ),
      columnType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>(
        'sqlite3_column_type',
      ),
      columnInt = lib.lookupFunction<_ColIntNative, _ColIntDart>(
        'sqlite3_column_int64',
      ),
      columnDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>(
        'sqlite3_column_double',
      ),
      columnText = lib.lookupFunction<_ColTextNative, _ColTextDart>(
        'sqlite3_column_text',
      );

  static final _Sqlite instance = _Sqlite._(
    DynamicLibrary.open('/lib/x86_64-linux-gnu/libsqlite3.so.0'),
  );

  final _OpenDart open;
  final _CloseDart close;
  final _ExecDart exec;
  final _ErrmsgDart errmsg;
  final _PrepareDart prepare;
  final _StepDart step;
  final _FinalizeDart finalize;
  final _ColCountDart columnCount;
  final _ColNameDart columnName;
  final _ColTypeDart columnType;
  final _ColIntDart columnInt;
  final _ColDoubleDart columnDouble;
  final _ColTextDart columnText;
}

class FfiSiteExecutor implements SiteLibrarySqlExecutor {
  FfiSiteExecutor._(this._db);

  final Pointer<Void> _db;
  bool _closed = false;

  static Future<FfiSiteExecutor> openDb(String path) async {
    final s = _Sqlite.instance;
    final pathPtr = path.toNativeUtf8();
    final dbPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.open(pathPtr, dbPtr);
      final db = dbPtr.value;
      if (rc != 0) {
        final msg = db == nullptr
            ? 'sqlite3_open failed rc=$rc'
            : s.errmsg(db).toDartString();
        if (db != nullptr) s.close(db);
        throw StateError(msg);
      }
      return FfiSiteExecutor._(db);
    } finally {
      calloc.free(pathPtr);
      calloc.free(dbPtr);
    }
  }

  String _err() {
    try {
      return _Sqlite.instance.errmsg(_db).toDartString();
    } catch (_) {
      return 'unknown sqlite error';
    }
  }

  void _execRaw(String sql) {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    try {
      final rc = s.exec(_db, sqlPtr, nullptr, nullptr, nullptr);
      if (rc != 0) {
        throw StateError(
          '${_err()} [sql head: ${sql.length > 100 ? sql.substring(0, 100) : sql}]',
        );
      }
    } finally {
      calloc.free(sqlPtr);
    }
  }

  @override
  Future<void> execute(String sql) async => _execRaw(sql);

  @override
  Future<void> executeBatch(List<String> statements) async {
    // sqflite Batch semantics: whole batch in one transaction,
    // any failure rolls the whole batch back and throws.
    _execRaw('BEGIN');
    try {
      for (final st in statements) {
        _execRaw(st);
      }
    } catch (e) {
      try {
        _execRaw('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
    _execRaw('COMMIT');
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    final stmtPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.prepare(_db, sqlPtr, -1, stmtPtr, nullptr);
      if (rc != 0) throw StateError(_err());
      final stmt = stmtPtr.value;
      final rows = <Map<String, Object?>>[];
      try {
        final n = s.columnCount(stmt);
        final names = <String>[
          for (var i = 0; i < n; i++) s.columnName(stmt, i).toDartString(),
        ];
        while (true) {
          final stepRc = s.step(stmt);
          if (stepRc == 101) break; // SQLITE_DONE
          if (stepRc != 100) throw StateError(_err()); // not ROW
          final row = <String, Object?>{};
          for (var i = 0; i < n; i++) {
            final type = s.columnType(stmt, i);
            Object? value;
            switch (type) {
              case 1: // INTEGER
                value = s.columnInt(stmt, i);
              case 2: // FLOAT
                value = s.columnDouble(stmt, i);
              case 3: // TEXT
                final p = s.columnText(stmt, i);
                value = p == nullptr ? null : p.toDartString();
              case 5: // NULL
                value = null;
              default: // BLOB etc: expose as text form
                final p = s.columnText(stmt, i);
                value = p == nullptr ? null : p.toDartString();
            }
            row[names[i]] = value;
          }
          rows.add(row);
        }
      } finally {
        s.finalize(stmt);
      }
      return rows;
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtPtr);
    }
  }

  Future<int> count(String table) async {
    final rows = await query('SELECT COUNT(*) AS c FROM "$table"');
    return (rows.first['c'] as num).toInt();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _Sqlite.instance.close(_db);
  }
}

/// FFI materializer: same SQL shape as SqfliteSegmentMaterializer
/// (ATTACH staging, rewrite CREATE names, INSERT SELECT, rebuild
/// indexes), driven through the FFI executor instead of sqflite.
class FfiSegmentMaterializer implements SiteLibrarySegmentMaterializer {
  const FfiSegmentMaterializer();

  @override
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  }) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    await target.parent.create(recursive: true);
    final db = await FfiSiteExecutor.openDb(targetPath);
    try {
      final escaped = stagingPath.replaceAll("'", "''");
      await db.execute("ATTACH DATABASE '$escaped' AS stage");
      try {
        final prefix = 'seg_${segment}_';
        final tables = await db.query(
          "SELECT name, sql FROM stage.sqlite_master "
          "WHERE type='table' AND name LIKE '$prefix%' "
          "AND name <> '${prefix}manifest'",
        );
        for (final row in tables) {
          final prefixed = '${row['name']}';
          final bare = prefixed.substring(prefix.length);
          final ddl = '${row['sql']}'.replaceFirst(prefixed, '"$bare"');
          await db.execute(ddl);
          await db.execute(
            'INSERT INTO "$bare" SELECT * FROM stage."$prefixed"',
          );
        }
        final indexes = await db.query(
          "SELECT name, sql, tbl_name FROM stage.sqlite_master "
          "WHERE type='index' AND sql IS NOT NULL "
          "AND tbl_name LIKE '$prefix%'",
        );
        for (final row in indexes) {
          final tbl = '${row['tbl_name']}';
          if (tbl == '${prefix}manifest') continue;
          final bare = tbl.substring(prefix.length);
          try {
            await db.execute('${row['sql']}'.replaceFirst(tbl, '"$bare"'));
          } catch (_) {
            // Index rebuild failure does not block landing (same
            // stance as production materializer).
          }
        }
      } finally {
        await db.execute('DETACH DATABASE stage');
      }
    } finally {
      await db.close();
    }
  }
}


// ---- adversarial delivery -------------------------------------------------

/// Re-chunk a byte stream into events of [sizes] (cycled).
Stream<List<int>> rechunk(Stream<List<int>> source, List<int> sizes) async* {
  final buffer = <int>[];
  var idx = 0;
  await for (final chunk in source) {
    buffer.addAll(chunk);
    while (buffer.length >= sizes[idx % sizes.length]) {
      final n = sizes[idx % sizes.length];
      idx++;
      yield buffer.sublist(0, n);
      buffer.removeRange(0, n);
    }
  }
  if (buffer.isNotEmpty) yield buffer;
}

/// Control consumer in the OLD shape: the byte stream is cut
/// into independent 30720-byte segments and each segment is
/// decoded on its own (what a state-restarting runtime does to
/// a stateful chunk decoder). Must throw on the fixture.
Future<void> oldStyleConsume(List<int> bytes) async {
  const segment = 30720;
  for (var at = 0; at < bytes.length; at += segment) {
    final end = min(at + segment, bytes.length);
    utf8.decode(bytes.sublist(at, end));
  }
}

// ---- fixture builder ------------------------------------------------------

String _sqlText(String value) => "'${value.replaceAll("'", "''")}'";

String _insertSql(String table, List<Object?> values) {
  final parts = [
    for (final v in values)
      if (v == null)
        'NULL'
      else if (v is num)
        '$v'
      else
        _sqlText('$v'),
  ];
  return 'INSERT INTO $table VALUES(${parts.join(',')});';
}

/// Builds a real three-segment bundle .sql whose actress
/// payload carries one huge line: 'x' followed by 40000
/// repetitions of a 3-byte character, so every 30720-byte
/// boundary inside it falls in the middle of a character.
/// Payloads/signatures are computed with the production
/// functions over an FFI staging db, then the whole fixture is
/// serialized back to .sql text (dump order: bundle manifest,
/// segment manifests, payload tables).
Future<File> buildAdversarialBundle(Directory dir) async {
  final stagingPath = '${dir.path}/fixture_staging.db';
  final db = await FfiSiteExecutor.openDb(stagingPath);
  final bigText = 'x${'修' * 40000}';
  try {
    await db.execute(
      'CREATE TABLE seg_site_stations(site_id TEXT, kind TEXT, name TEXT)',
    );
    await db.execute(
      'CREATE TABLE seg_site_station_code(site_id TEXT, code_sha256 TEXT, code_text TEXT)',
    );
    await db.execute(
      'CREATE TABLE seg_site_station_assets(asset_id TEXT, md5 TEXT)',
    );
    await db.execute(
      'CREATE TABLE seg_actress_videos(vod_id TEXT, title TEXT)',
    );
    await db.execute(
      'CREATE TABLE seg_magnet_videos(vod_id TEXT, title TEXT)',
    );
    await db.execute(
      _insertSql('seg_site_stations', ['demo', 'pyImport', '演示站']),
    );
    final codeText = "print('修仙')\n";
    await db.execute(
      _insertSql('seg_site_station_code', [
        'demo',
        computeSegmentTableSha256Marker(codeText),
        codeText,
      ]),
    );
    await db.execute(
      _insertSql('seg_actress_videos', ['v1', bigText]),
    );
    await db.execute(_insertSql('seg_actress_videos', ['v2', '普通标题']));
    await db.execute(
      _insertSql('seg_magnet_videos', ['m1', '磁力标题']),
    );

    final sitePayload = computeSiteLibraryPayloadSha256(
      stations: [(siteId: 'demo', kind: 'pyImport', name: '演示站')],
      codes: [
        (
          siteId: 'demo',
          codeSha256: computeSegmentTableSha256Marker(codeText),
        ),
      ],
      assets: const [],
      manifest: (
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: 'adv1',
      ),
    );
    final actressPayload = await computeBundleSegmentPayload(
      db,
      segment: 'actress',
      prefixedTables: ['seg_actress_videos'],
    );
    final magnetPayload = await computeBundleSegmentPayload(
      db,
      segment: 'magnet',
      prefixedTables: ['seg_magnet_videos'],
    );
    final bundlePayload = computeBundlePayloadSha256({
      'site': sitePayload,
      'actress': actressPayload,
      'magnet': magnetPayload,
    });

    final out = StringBuffer()
      ..writeln(
        'CREATE TABLE bundle_manifest(id INTEGER, bundle_format TEXT, '
        'format_version TEXT, core_version TEXT, bundle_version TEXT, '
        'segments TEXT, payload_sha256 TEXT, signature TEXT);',
      )
      ..writeln(
        _insertSql('bundle_manifest', [
          1,
          'fanren_bundle',
          '1',
          '2026.11.27',
          'adv1',
          'site,actress,magnet',
          bundlePayload,
          computeSiteLibrarySignature(bundlePayload),
        ]),
      );
    for (final (seg, payload, rows) in [
      ('site', sitePayload, 2),
      ('actress', actressPayload, 2),
      ('magnet', magnetPayload, 1),
    ]) {
      out
        ..writeln(
          'CREATE TABLE seg_${seg}_manifest(id INTEGER, segment TEXT, '
          'format_version TEXT, core_version TEXT, library_version TEXT, '
          'row_count INTEGER, payload_sha256 TEXT, signature TEXT);',
        )
        ..writeln(
          _insertSql('seg_${seg}_manifest', [
            1,
            seg,
            '1',
            '2026.11.27',
            'adv1',
            rows,
            payload,
            computeSiteLibrarySignature(payload),
          ]),
        );
    }
    // Payload tables: dump DDL + rows from the staging db.
    for (final table in [
      'seg_site_stations',
      'seg_site_station_code',
      'seg_site_station_assets',
      'seg_actress_videos',
      'seg_magnet_videos',
    ]) {
      final ddl = await db.query(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='$table'",
      );
      out.writeln('${ddl.first['sql']};');
      final cols = await db.query('PRAGMA table_info("$table")');
      final colNames = [for (final c in cols) '${c['name']}'];
      final rows = await db.query('SELECT * FROM "$table" ORDER BY rowid');
      for (final row in rows) {
        out.writeln(
          _insertSql(table, [for (final c in colNames) row[c]]),
        );
      }
    }
    final file = File('${dir.path}/adversarial_bundle.sql');
    await file.writeAsString(out.toString());
    return file;
  } finally {
    await db.close();
  }
}

/// sha256 of one text value (site code hash口径).
String computeSegmentTableSha256Marker(String text) =>
    sha256.convert(utf8.encode(text)).toString();

// ---- driver ---------------------------------------------------------------

Future<void> runAdversarialCase({
  required Directory dir,
  required File bundle,
  required Stream<List<int>> Function(Stream<List<int>>) wrapper,
  required String label,
}) async {
  final caseDir = Directory('${dir.path}/case_$label');
  await caseDir.create(recursive: true);
  final siteDbPath = '${caseDir.path}/site_library.db';
  await File(siteDbPath).writeAsString('OLDDB');

  Future<({bool ok, String? error, String? detail})> Function(String)
  lander(String segment, Map<String, int> expected) {
    return (String segmentDbPath) async {
      final db = await FfiSiteExecutor.openDb(segmentDbPath);
      try {
        for (final entry in expected.entries) {
          final count = await db.count(entry.key);
          expect(count, entry.value, reason: '$segment.${entry.key}');
        }
        return (ok: true, error: null, detail: 'ok');
      } finally {
        await db.close();
      }
    };
  }

  final importer = SiteLibraryBundleImporter(
    executorFactory: (path) => FfiSiteExecutor.openDb(path),
    materializer: const FfiSegmentMaterializer(),
    actressLander: lander('actress', {'videos': 2}),
    magnetLander: lander('magnet', {'videos': 1}),
    segmentDbPostProcess: (segment, path) async {},
    decodedStreamWrapper: wrapper,
  );
  final outcome = await importer.importBundle(
    sqlPath: bundle.path,
    siteDbPath: siteDbPath,
    workDir: caseDir.path,
    onProgress: (_) {},
  );
  expect(outcome, isNotNull);
  expect(outcome!.ok, isTrue, reason: '[$label] ${outcome.error}');
  expect(outcome.stationCount, 1);
  expect(outcome.segmentResults.every((r) => r.ok), isTrue);
  // Site segment landed: old db replaced by a real SQLite file.
  final siteBytes = await File(siteDbPath).readAsBytes();
  expect(siteBytes.length, greaterThan(100));
  expect(
    String.fromCharCodes(siteBytes.take(15)),
    'SQLite format 3'.substring(0, 15),
  );
}

void main() {
  late Directory dir;
  late File bundle;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('adv_bundle_');
    bundle = await buildAdversarialBundle(dir);
  });
  tearDownAll(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('control: old-style per-30720-segment decode dies on fixture', () async {
    final bytes = await bundle.readAsBytes();
    expect(bytes.length, greaterThan(30720 * 3));
    await expectLater(oldStyleConsume(bytes), throwsFormatException);
  });

  test('chain survives exact 30720-byte delivery', () async {
    await runAdversarialCase(
      dir: dir,
      bundle: bundle,
      label: 'seg30720',
      wrapper: (s) => rechunk(s, const [30720]),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('chain survives random chunk delivery', () async {
    final random = Random(20261128);
    final sizes = [for (var i = 0; i < 64; i++) 1 + random.nextInt(65536)];
    await runAdversarialCase(
      dir: dir,
      bundle: bundle,
      label: 'random',
      wrapper: (s) => rechunk(s, sizes),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('chain survives 1-byte delivery', () async {
    await runAdversarialCase(
      dir: dir,
      bundle: bundle,
      label: 'onebyte',
      wrapper: (s) => rechunk(s, const [1]),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('SqlDecodeFailure carries offset + hex context', () async {
    // 'ab' + first byte of a 3-byte char, then ASCII: the line
    // decoder must fail with定点 info.
    final bytes = <int>[0x61, 0x62, 0xE4, 0x41, 0x0A];
    Object? caught;
    try {
      await for (final _ in sqlTextLines(Stream.value(bytes))) {}
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<SqlDecodeFailure>());
    final failure = caught! as SqlDecodeFailure;
    expect(failure.lineNumber, 1);
    expect(failure.offset, 3);
    expect(failure.contextHex, contains('e4'));
    expect(importFailureZh(failure), contains('编码不对'));
  });

  test('ImportDebugLog writes stage + decode定点 to MYTV/db file', () async {
    final logDir = Directory('${dir.path}/MYTV/db');
    ImportDebugLog.directoryResolver = () async => logDir;
    try {
      await ImportDebugLog.reset('对抗测试');
      await ImportDebugLog.record(
        stage: '演员段校验',
        error: SqlDecodeFailure(
          message: 'Unexpected extension byte',
          lineNumber: 7,
          lineStartOffset: 100,
          offset: 24576,
          contextHex: '61 e4 bf',
        ),
        stack: StackTrace.current,
      );
      final text = await File(
        '${logDir.path}/import_debug.log',
      ).readAsString();
      expect(text, contains('演员段校验'));
      expect(text, contains('24576'));
      expect(text, contains('61 e4 bf'));
      expect(text, contains('SqlDecodeFailure'));
    } finally {
      ImportDebugLog.directoryResolver = null;
    }
  });
}
