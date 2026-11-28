import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/site_library_bundle.dart';

/// 合并文件分段导入测试（站点库续办批）：假执行器按夹具数据
/// 回答查询（与 site_library_test 同款分工——流式执行通道只
/// 记录、校验查询走夹具），物化器/落位链全用假件记录调用。
/// T 行 payload 的规范口径另有 Python 独立实现算出的锚点常量
/// 对账（见第一组），不是生产函数自证。

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

String _sign(String payload) => computeSiteLibrarySignature(payload);

/// 夹具：三段齐全的小合并文件。
/// - site 段：1 站（demo py）＋1 代码行＋0 资产，payload 走现行
///   站点库口径（生产函数拼，site_library_test 已有独立实现
///   对账过）。
/// - actress 段：1 张表 videos（3 行），payload 用锚点常量
///   （Python 按 SEGMENT_SPEC §4 独立算出）。
/// - magnet 段：1 张表 videos（1 行 magnet: 地址），payload
///   在夹具里按同口径现算（表哈希走生产函数——锚点组已证明
///   生产函数与 Python 口径一致）。
class _BundleFixture {
  _BundleFixture({
    this.actressCoreVersion = '2026.11.27',
    this.tamperBundleSignature = false,
    this.tamperMagnetDeclaredPayload = false,
    this.bundleFormatVersion = '1',
  }) {
    final demoCode = "print('hi')\n";
    siteStationRows = [
      {
        'site_id': 'demo',
        'kind': 'pyImport',
        'name': '演示站',
        'canon_id': 'demo',
        'content_type': 'video',
        'zone': 'video',
        'is_adult': 0,
        'sort_order': 0,
        'verify_note': null,
      },
    ];
    siteCodeRows = [
      {
        'site_id': 'demo',
        'code_sha256': _sha(demoCode),
        'code_text': demoCode,
        'file_name': 'demo.py',
        'ext': null,
        'class_name': null,
        'jar_asset_id': null,
      },
    ];
    sitePayload = computeSiteLibraryPayloadSha256(
      stations: [(siteId: 'demo', kind: 'pyImport', name: '演示站')],
      codes: [(siteId: 'demo', codeSha256: _sha(demoCode))],
      assets: const [],
      manifest: (
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: '20261127',
      ),
    );
  }

  final String actressCoreVersion;
  final bool tamperBundleSignature;
  final bool tamperMagnetDeclaredPayload;
  final String bundleFormatVersion;

  late final List<Map<String, Object?>> siteStationRows;
  late final List<Map<String, Object?>> siteCodeRows;
  late final String sitePayload;

  /// actress 段锚点（Python 独立实现，见文件头）：
  /// seg_actress_videos(vod_id,title) 三行
  /// ('a1','标题一') ('a2',NULL) ('b1','x;y')。
  static const actressPayload =
      '103a0cf95f53a93281de1720fc86c03ab0e043e3a466a1e938f4c611952a6604';
  static const actressSignature =
      '8d31faae1ef7078bc45eb07f3692d992a9535965821cfb65f91d9f17222d3713';

  static final actressVideoRows = <Map<String, Object?>>[
    {'vod_id': 'a1', 'title': '标题一'},
    {'vod_id': 'a2', 'title': null},
    {'vod_id': 'b1', 'title': 'x;y'},
  ];

  static final magnetVideoRows = <Map<String, Object?>>[
    {'vod_id': 'm1', 'title': '磁力一'},
  ];

  Map<String, Object?> get siteManifest => {
    'segment': 'site',
    'format_version': '1',
    'core_version': '2026.11.27',
    'library_version': '20261127',
    // schema_meta(9) + stations(1) + code(1) + assets(0) = 11
    'row_count': 11,
    'payload_sha256': sitePayload,
    'signature': _sign(sitePayload),
  };

  Map<String, Object?> get actressManifest => {
    'segment': 'actress',
    'format_version': '1',
    'core_version': actressCoreVersion,
    'library_version': '20261127v5',
    'row_count': 3,
    'payload_sha256': actressPayload,
    'signature': actressSignature,
  };

  /// magnet 段 payload 在测试运行时按锚点已证的口径现算
  /// （见 setUpMagnetPayload）。
  String magnetPayload = '';
  String get magnetDeclaredPayload =>
      tamperMagnetDeclaredPayload ? 'deadbeef' * 8 : magnetPayload;

  Map<String, Object?> get magnetManifest => {
    'segment': 'magnet',
    'format_version': '1',
    'core_version': '2026.11.27',
    'library_version': '20261127',
    'row_count': 1,
    'payload_sha256': magnetDeclaredPayload,
    'signature': _sign(magnetDeclaredPayload),
  };

  Map<String, Object?> get bundleRow {
    final payload = computeBundlePayloadSha256({
      'site': sitePayload,
      'actress': actressPayload,
      'magnet': magnetDeclaredPayload,
    });
    return {
      'bundle_format': 'fanren_bundle',
      'format_version': bundleFormatVersion,
      'core_version': '2026.11.27',
      'bundle_version': '20261127',
      'segments': 'site,actress,magnet',
      'payload_sha256': payload,
      'signature': tamperBundleSignature ? 'deadbeef' : _sign(payload),
    };
  }
}

/// 假执行器：按 SQL 形态回夹具数据。staging 与物化后的站点库
/// 临时文件共用一个工厂时按路径分流（临时文件走空执行器）。
class _BundleFakeExecutor implements SiteLibrarySqlExecutor {
  _BundleFakeExecutor(this.fixture);

  final _BundleFixture fixture;
  var closed = false;

  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains("name='bundle_manifest'")) {
      return [
        {'name': 'bundle_manifest'},
      ];
    }
    final nameEq = RegExp(r"name='([A-Za-z0-9_]+)'").firstMatch(sql);
    if (nameEq != null && sql.contains('sqlite_master')) {
      // 段 manifest 存在性查询：夹具里三段清单都在。
      return [
        {'name': nameEq.group(1)},
      ];
    }
    if (sql.contains("name LIKE 'seg_site_%'")) {
      return [
        {'name': 'seg_site_schema_meta'},
        {'name': 'seg_site_stations'},
        {'name': 'seg_site_station_code'},
        {'name': 'seg_site_station_assets'},
        {'name': 'seg_site_manifest'},
      ];
    }
    if (sql.contains("name LIKE 'seg_actress_%'")) {
      return [
        {'name': 'seg_actress_videos'},
        {'name': 'seg_actress_manifest'},
      ];
    }
    if (sql.contains("name LIKE 'seg_magnet_%'")) {
      return [
        {'name': 'seg_magnet_videos'},
        {'name': 'seg_magnet_manifest'},
      ];
    }
    if (sql.contains('FROM bundle_manifest')) return [fixture.bundleRow];
    if (sql.contains('FROM seg_site_manifest')) return [fixture.siteManifest];
    if (sql.contains('FROM seg_actress_manifest')) {
      return [fixture.actressManifest];
    }
    if (sql.contains('FROM seg_magnet_manifest')) {
      return [fixture.magnetManifest];
    }
    if (sql.contains('FROM seg_site_stations')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': fixture.siteStationRows.length},
        ];
      }
      return fixture.siteStationRows;
    }
    if (sql.contains('FROM seg_site_station_code')) {
      return fixture.siteCodeRows;
    }
    if (sql.contains('FROM seg_site_station_assets')) {
      return const [];
    }
    if (sql.contains('PRAGMA table_info("seg_actress_videos")')) {
      return [
        {'name': 'vod_id'},
        {'name': 'title'},
      ];
    }
    if (sql.contains('PRAGMA table_info("seg_magnet_videos")')) {
      return [
        {'name': 'vod_id'},
        {'name': 'title'},
      ];
    }
    if (sql.contains('FROM "seg_actress_videos"')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': _BundleFixture.actressVideoRows.length},
        ];
      }
      return _BundleFixture.actressVideoRows;
    }
    if (sql.contains('FROM "seg_magnet_videos"')) {
      if (sql.contains('COUNT(*)')) {
        return [
          {'c': _BundleFixture.magnetVideoRows.length},
        ];
      }
      return _BundleFixture.magnetVideoRows;
    }
    if (sql.contains('FROM "seg_site_schema_meta"')) {
      return [
        {'c': 9},
      ];
    }
    if (sql.contains('FROM "seg_site_stations"')) {
      return [
        {'c': 1},
      ];
    }
    if (sql.contains('FROM "seg_site_station_code"')) {
      return [
        {'c': 1},
      ];
    }
    if (sql.contains('FROM "seg_site_station_assets"')) {
      return [
        {'c': 0},
      ];
    }
    return [];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 空执行器（物化后的站点库临时文件补 manifest 时用）。
class _EmptyExecutor implements SiteLibrarySqlExecutor {
  final executed = <String>[];

  @override
  Future<void> execute(String sql) async {
    executed.add(sql);
  }

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async => [];

  @override
  Future<void> close() async {}
}

/// 无合并清单的假执行器：sqlite_master 查 bundle_manifest
/// 回空（模拟单段文件 staging 后的真实形态）。
class _NoBundleExecutor implements SiteLibrarySqlExecutor {
  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async => [];

  @override
  Future<void> close() async {}
}

/// 假物化器：记录调用、往目标路径写占位内容。
class _FakeMaterializer implements SiteLibrarySegmentMaterializer {
  final calls = <String>[];

  @override
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  }) async {
    calls.add(segment);
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('SEGDB-$segment');
  }
}

void main() {
  group('规范哈希锚点（Python 独立实现对账）', () {
    test('表哈希与 T 行 payload 与 SEGMENT_SPEC §4 口径一致', () async {
      final executor = _BundleFakeExecutor(_BundleFixture());
      final tableHash = await computeSegmentTableSha256(
        executor,
        'seg_actress_videos',
      );
      expect(
        tableHash,
        '21126603406552f28b32b426327f9dd61cfdee40a282b70d792f650df9c1162f',
      );
      final payload = await computeBundleSegmentPayload(
        executor,
        segment: 'actress',
        prefixedTables: ['seg_actress_videos'],
      );
      expect(payload, _BundleFixture.actressPayload);
      expect(
        computeSiteLibrarySignature(payload),
        _BundleFixture.actressSignature,
      );
    });
  });

  group('SiteLibraryBundleImporter 分段导入', () {
    late Directory tempDir;
    late _BundleFixture fixture;
    late _FakeMaterializer materializer;
    late List<String> actressLanded;
    late List<String> magnetLanded;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('bundle_');
      fixture = _BundleFixture();
      materializer = _FakeMaterializer();
      actressLanded = [];
      magnetLanded = [];
      // magnet 段 payload：用锚点组已证口径的假执行器现算。
      final probe = _BundleFakeExecutor(fixture);
      fixture.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<File> writeBundleSql() async {
      final file = File('${tempDir.path}/凡人修仙站点.sql');
      await file.writeAsString(
        'CREATE TABLE bundle_manifest(id INTEGER);\n'
        "INSERT INTO bundle_manifest VALUES(1);\n",
      );
      return file;
    }

    SiteLibraryBundleImporter makeImporter({_BundleFixture? useFixture}) {
      final f = useFixture ?? fixture;
      return SiteLibraryBundleImporter(
        executorFactory: (path) async {
          if (path.contains('bundle_staging')) {
            await File(path).writeAsString('STAGING');
            return _BundleFakeExecutor(f);
          }
          return _EmptyExecutor();
        },
        materializer: materializer,
        actressLander: (path) async {
          actressLanded.add(path);
          return (ok: true, error: null, detail: '作品 3 部');
        },
        magnetLander: (path) async {
          magnetLanded.add(path);
          return (ok: true, error: null, detail: '新增作品 1 部');
        },
        segmentDbPostProcess: (segment, path) async {},
      );
    }

    Future<SiteLibraryImportOutcome?> runImport({
      _BundleFixture? useFixture,
    }) async {
      final f = useFixture ?? fixture;
      if (f.magnetPayload.isEmpty) {
        final probe = _BundleFakeExecutor(f);
        f.magnetPayload = await computeBundleSegmentPayload(
          probe,
          segment: 'magnet',
          prefixedTables: ['seg_magnet_videos'],
        );
      }
      final sql = await writeBundleSql();
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      await Directory('${tempDir.path}/site_library').create();
      await File(siteDbPath).writeAsString('OLDDB');
      final outcome = await makeImporter(useFixture: useFixture).importBundle(
        sqlPath: sql.path,
        siteDbPath: siteDbPath,
        workDir: '${tempDir.path}/site_library',
        onProgress: (_) {},
      );
      return outcome;
    }

    test('三段全过：演员/磁力落位、站点段跳过、逐段结果齐', () async {
      final outcome = await runImport();
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue, reason: outcome.error);
      // 站点已内置：站数不再由 bundle 落位产出。
      expect(outcome.stationCount, 0);
      expect(outcome.segmentResults, hasLength(3));
      expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      final siteResult = outcome.segmentResults
          .firstWhere((r) => r.segment == 'site');
      expect(siteResult.detail, contains('已跳过'));
      expect(siteResult.detail, contains('站点已内置'));
      // 物化只走 actress/magnet 两段，站点段不物化不落位。
      expect(materializer.calls, ['actress', 'magnet']);
      expect(actressLanded, hasLength(1));
      expect(magnetLanded, hasLength(1));
      // 站点库文件一字不动、无 .bak。
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      expect(await File(siteDbPath).readAsString(), 'OLDDB');
      expect(await File('$siteDbPath.bak').exists(), isFalse);
      // staging 与段临时文件清干净。
      expect(
        await File(
          '${tempDir.path}/site_library/bundle_staging.db',
        ).exists(),
        isFalse,
      );
      expect(
        await File(
          '${tempDir.path}/site_library/segment_actress.db',
        ).exists(),
        isFalse,
      );
    });

    test('整库 format_version 写 2 与 2099：照常整份导入（2026-11-28 版本门全拆）', () async {
      // G15 整库格式门此前无专测：拆门后 bundle_manifest 的
      // format_version 写任意值都只随清单留痕，整份照常导入
      // （签名/哈希按段 payload 算、与 format 值无关，夹具
      // 改 format 不影响自洽）。
      for (final v in ['2', '2099']) {
        final outcome = await runImport(
          useFixture: _BundleFixture(bundleFormatVersion: v),
        );
        expect(outcome, isNotNull);
        expect(outcome!.ok, isTrue, reason: 'format_version=$v: ${outcome.error}');
        expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      }
      expect(actressLanded, hasLength(2));
      expect(magnetLanded, hasLength(2));
    });

    test('段清单版本字段不符：不拒段，演员/磁力照常落位', () async {
      // 2026-11-28 版本门全拆：段 manifest 的 core_version
      // 与整库不一致不再是拒收理由，整文件层同样不比对
      // 版本字段（只验清单/payload/签名）。
      final outcome = await runImport(
        useFixture: _BundleFixture(actressCoreVersion: '1999.01.01'),
      );
      expect(outcome, isNotNull);
      expect(outcome!.ok, isTrue, reason: outcome.error);
      expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      expect(actressLanded, hasLength(1));
      expect(magnetLanded, hasLength(1));
    });

    test('一段 payload 被篡改：整库不导、一段不落、错误定位到该段', () async {
      final tampered = _BundleFixture(tamperMagnetDeclaredPayload: true);
      // 夹具的 magnet 清单 payload/签名按篡改值自洽（整文件层
      // 按声明值算也自洽），段内重算对不上才拒——与真篡改同型。
      // 新口径：一份数据库一次激活，坏一段整库不导。
      final probe = _BundleFakeExecutor(tampered);
      tampered.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
      final outcome = await runImport(useFixture: tampered);
      expect(outcome, isNotNull);
      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('磁力库'));
      expect(outcome.error, contains('哈希'));
      final bySegment = {
        for (final r in outcome.segmentResults) r.segment: r,
      };
      expect(bySegment['magnet']!.ok, isFalse);
      expect(bySegment['magnet']!.error, contains('磁力库'));
      // 本身完好的段也不落位：整库未导入。
      expect(bySegment['site']!.ok, isFalse);
      expect(bySegment['actress']!.ok, isFalse);
      expect(materializer.calls, isEmpty);
      expect(actressLanded, isEmpty);
      expect(magnetLanded, isEmpty);
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      expect(await File(siteDbPath).readAsString(), 'OLDDB');
    });

    test('整文件签名不对：全拒、一段不落、旧站点库不动', () async {
      final outcome = await runImport(
        useFixture: _BundleFixture(tamperBundleSignature: true),
      );
      expect(outcome, isNotNull);
      expect(outcome!.ok, isFalse);
      expect(outcome.error, contains('整文件签名'));
      expect(outcome.segmentResults, isEmpty);
      expect(materializer.calls, isEmpty);
      expect(actressLanded, isEmpty);
      expect(magnetLanded, isEmpty);
      final siteDbPath = '${tempDir.path}/site_library/site_library.db';
      expect(await File(siteDbPath).readAsString(), 'OLDDB');
      expect(await File('$siteDbPath.bak').exists(), isFalse);
    });

    test('非合并文件：staging 后查无 bundle_manifest 表，回 null 交回单段路',
        () async {
      final plain = await writeBundleSql();
      final importer = SiteLibraryBundleImporter(
        executorFactory: (path) async {
          await File(path).writeAsString('STAGING');
          return _NoBundleExecutor();
        },
        materializer: materializer,
        actressLander: (path) async =>
            (ok: true, error: null, detail: null),
        magnetLander: (path) async =>
            (ok: true, error: null, detail: null),
        segmentDbPostProcess: (segment, path) async {},
      );
      final outcome = await importer.importBundle(
        sqlPath: plain.path,
        siteDbPath: '${tempDir.path}/site_library/site_library.db',
        workDir: '${tempDir.path}/site_library',
        onProgress: (_) {},
      );
      expect(outcome, isNull);
      expect(materializer.calls, isEmpty);
    });

    test('粗扫：含 bundle_manifest 字样才命中', () async {
      final bundle = await writeBundleSql();
      expect(
        await SiteLibraryBundleImporter.mightBeBundle(bundle.path),
        isTrue,
      );
      final plain = File('${tempDir.path}/站点库.sql');
      await plain.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n'
        "INSERT INTO stations VALUES('demo');\n",
      );
      expect(
        await SiteLibraryBundleImporter.mightBeBundle(plain.path),
        isFalse,
      );
    });
  });

  group('SiteLibraryService 路由（单段兼容＋合并分流）', () {
    late Directory root;
    late Directory libDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('bundle_svc_');
      libDir = Directory('${root.path}/site_library')..createSync();
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// 0 站单段库的合法 payload（空集＋清单行）。
    String emptyPayload() => computeSiteLibraryPayloadSha256(
      stations: const [],
      codes: const [],
      assets: const [],
      manifest: (
        formatVersion: '1',
        coreVersion: '2026.11.27',
        libraryVersion: '20261127',
      ),
    );

    SiteLibrarySqlExecutor legacyExecutor() {
      final payload = emptyPayload();
      return _LegacyFakeExecutor(
        meta: {
          'format': 'site_library',
          'schema_version': '1',
          'station_count': '0',
          'library_version': '20261127',
        },
        manifestRow: {
          'library_version': '20261127',
          'station_count': 0,
          'payload_sha256': payload,
          'signature': _sign(payload),
          'format_version': '1',
          'core_version': '2026.11.27',
        },
      );
    }

    test('单段文件兼容：粗扫不命中，走现行单段路导入成功', () async {
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        importer: SiteLibraryImporter(
          executorFactory: (path) async {
            await File(path).writeAsString('NEWDB');
            return legacyExecutor();
          },
        ),
        readExecutorFactory: (_) async => legacyExecutor(),
        assetLoader: (_) async => '[]',
      );
      final sql = File('${root.path}/站点库.sql');
      await sql.writeAsString(
        'CREATE TABLE stations(site_id TEXT);\n'
        "INSERT INTO stations VALUES('demo');\n",
      );
      final outcome = await service.importLocalFile(localPath: sql.path);
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.segmentResults, isEmpty);
      expect(outcome.stationCount, 0);
      expect(service.imported, isTrue);
      expect(
        await File('${libDir.path}/site_library.db').readAsString(),
        'NEWDB',
      );
    });

    test('合并文件经服务层：逐段结果回来、站点段报已跳过', () async {
      final fixture = _BundleFixture();
      final probe = _BundleFakeExecutor(fixture);
      fixture.magnetPayload = await computeBundleSegmentPayload(
        probe,
        segment: 'magnet',
        prefixedTables: ['seg_magnet_videos'],
      );
      final bundleImporter = SiteLibraryBundleImporter(
        executorFactory: (path) async {
          if (path.contains('bundle_staging')) {
            await File(path).writeAsString('STAGING');
            return _BundleFakeExecutor(fixture);
          }
          return _EmptyExecutor();
        },
        materializer: _FakeMaterializer(),
        actressLander: (path) async =>
            (ok: true, error: null, detail: '作品 3 部'),
        magnetLander: (path) async =>
            (ok: true, error: null, detail: '新增作品 1 部'),
        segmentDbPostProcess: (segment, path) async {},
      );
      final service = SiteLibraryService(
        supportDirectoryProvider: () async => root,
        bundleImporter: bundleImporter,
        readExecutorFactory: (_) async => legacyExecutor(),
        assetLoader: (_) async => '[]',
      );
      final sql = File('${root.path}/凡人修仙站点.sql');
      await sql.writeAsString(
        'CREATE TABLE bundle_manifest(id INTEGER);\n'
        "INSERT INTO bundle_manifest VALUES(1);\n",
      );
      final outcome = await service.importLocalFile(localPath: sql.path);
      expect(outcome.ok, isTrue, reason: outcome.error);
      expect(outcome.segmentResults, hasLength(3));
      expect(outcome.segmentResults.every((r) => r.ok), isTrue);
      // 站点段不落位（站点已内置）：段结果报已跳过，站点库
      // 落点文件不产生。服务层自身的站点状态口径归站点库
      // 负责人，本例只断言 bundle 路由与逐段结果。
      final siteResult = outcome.segmentResults
          .firstWhere((r) => r.segment == 'site');
      expect(siteResult.detail, contains('已跳过'));
      expect(
        await File('${libDir.path}/site_library.db').exists(),
        isFalse,
      );
    });
  });
}

/// 单段（旧格式）假执行器：schema_meta/manifest/三表按夹具回。
class _LegacyFakeExecutor implements SiteLibrarySqlExecutor {
  _LegacyFakeExecutor({required this.meta, required this.manifestRow});

  final Map<String, String> meta;
  final Map<String, Object?> manifestRow;

  @override
  Future<void> execute(String sql) async {}

  @override
  Future<void> executeBatch(List<String> statements) async {}

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains('FROM schema_meta')) {
      return [
        for (final e in meta.entries) {'key': e.key, 'value': e.value},
      ];
    }
    if (sql.contains('FROM manifest')) return [manifestRow];
    if (sql.contains('FROM stations')) return [];
    if (sql.contains('FROM station_code')) return [];
    if (sql.contains('FROM station_assets')) return [];
    return [];
  }

  @override
  Future<void> close() async {}
}
