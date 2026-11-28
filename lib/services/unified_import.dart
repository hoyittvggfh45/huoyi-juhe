import 'dart:convert';
import 'dart:io';

/// 统一导入口的认库结果（2026-11-28 统一导入口批）：数据库管理
/// 页只留一个导入入口，用户选哪份文件都由软件按内容认库、走
/// 各自原有的导入路（校验、版本门、签名、落位语义一字不改，
/// 本文件只负责「认」，不负责「导」）。
enum UnifiedImportKind {
  /// 三段合并文件（bundle_manifest 在场）：走站点库服务的
  /// 分段导入器，三段各落各位。
  bundle,

  /// 站点库单段文件：走站点库服务单段路。
  siteLibrary,

  /// 女优库 .db 本体（SQLite 文件头）：走女优库 .db 收编路。
  actressDb,

  /// 女优库 .sql/.sql.gz（标准表、播放地址是 http 直链）：
  /// 走女优库 SQL 导入路。
  actressSql,

  /// 磁力库 .sql/.sql.gz（标准表、播放地址是 magnet 链接）：
  /// 走磁力并存合并路。
  magnetSql,

  /// 认不出：不许瞎导，页面给中文提示。
  unknown,
}

extension UnifiedImportKindLabel on UnifiedImportKind {
  /// 给用户看的中文名（进度与结果回报用）。
  String get labelZh => switch (this) {
    UnifiedImportKind.bundle => '三库合并文件',
    UnifiedImportKind.siteLibrary => '站点库',
    UnifiedImportKind.actressDb => '女优库',
    UnifiedImportKind.actressSql => '女优库',
    UnifiedImportKind.magnetSql => '磁力库',
    UnifiedImportKind.unknown => '未知文件',
  };
}

/// 流式认库嗅探器：按块扫文件（.sql.gz 先流式解压），每块按
/// latin1 解码做 ASCII 模式匹配（字节与字符一一对应、模式全
/// 是 ASCII，不会误码），内存里只留一小段尾巴做跨块匹配，
/// 绝不整文件读入、绝不走系统文件选择器。判定规则（按真实
/// 文件形态定，逐条有实证）：
///
/// 1. 文件头是 SQLite 魔数（`SQLite format 3`）→ 女优库 .db。
/// 2. 扫到 `bundle_manifest` → 合并文件。它在合并文件第 32
///    字节处，必然先于一切段表出现，命中即定（只在头部窗口
///    内查，命中即提前返回）。
/// 3. 全程扫到 `actress_library` 标记 → 女优库，优先级高于
///    一切磁力证据。合并库（女优库全量＋磁力线路）的身份标
///    记是 schema_meta 里的 `format='actress_library'` 一行，
///    但 sqlite .dump 把 schema_meta 建表放在**文件尾部**
///    （真文件实测：712MB 合并 .sql 里在偏移 712,165,951 /
///    712,166,048 处），不在任何头部窗口里；而它的磁力线路
///    段在更前面（第 25 条磁力在偏移 697,858,358）——旧实现
///    「头窗口查标记＋磁力满 25 条提前定案」必然把合并库误
///    判磁力（2026-11-28 真机实况）。所以女优标记必须全程
///    扫、磁力不得提前定案：扫完（或标记与标准表都已见时）
///    才定。纯磁力库实证（magnet_sql_convert_20261127/out/
///    磁力库.sql，106MB、99,301 条磁力）：全文 `actress_`
///    `library` 与 `schema_meta` 均 0 次，独立标记不会误伤
///    纯磁力库，不必退回组合判据。
/// 4. 扫到站点库独有标记（`station_code` / `INSERT INTO
///    stations`）→ 站点库单段。注意站点标记里**不含裸
///    `schema_meta`**：女优/合并文件同样有这张表，靠它认站
///    点必误判。合并文件的段表带 seg_ 前缀且 bundle 清单在
///    更前面，第 2 条先定，不会误判。
/// 5. 女优与磁力同结构（videos 等标准表），没有女优标记时
///    靠播放地址区分：磁力库的地址值以 `'magnet:` 开头。磁
///    力计数达 25 条 → 磁力（此判定排在女优标记之后，不再
///    提前定案）；没到线的小文件看 video_play_urls 首批样
///    本的地址形态定：样本是 magnet → 磁力，样本是 http →
///    女优（样本只看标记后 600 字节窗口内的字节，窗口外
///    的封面 http 不算证据）；样本没采到时磁力计数 >0 →
///    磁力；一条都没有、且有标准表 → 女优库。
/// 6. 以上都不命中（没有标准表、或读不出内容）→ unknown。
class UnifiedImportSniffer {
  UnifiedImportSniffer._();

  static const _sqliteMagic = 'SQLite format 3';

  /// 磁力计数参考线（保留作计数口径记录）：旧实现扫到这么
  /// 多条即提前定磁力，现已取消提前定案（见类注释第 3 条，
  /// 合并库的女优标记在磁力段之后），计数只在扫完后参与第
  /// 5 条的兜底判定。
  static const magnetDecisiveHits = 25;

  /// video_play_urls 样本窗口：标记后这么多字节内找地址形态。
  static const _sampleWindowBytes = 600;

  static Future<UnifiedImportKind> sniff(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      return UnifiedImportKind.unknown;
    }
    // 1. SQLite 文件头（.db 本体；.sql.gz 的头是 gzip 魔数，
    //    不会撞）。
    try {
      final head = await file.openRead(0, 16).fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      if (head.length >= _sqliteMagic.length &&
          String.fromCharCodes(head.take(_sqliteMagic.length)) ==
              _sqliteMagic) {
        return UnifiedImportKind.actressDb;
      }
    } catch (_) {
      return UnifiedImportKind.unknown;
    }
    // 2–5. 流式扫描（.gz 流式解压，解压失败按认不出）。
    try {
      return await _scanStream(file, isGz: path.toLowerCase().endsWith('.gz'));
    } catch (_) {
      return UnifiedImportKind.unknown;
    }
  }

  static Future<UnifiedImportKind> _scanStream(
    File file, {
    required bool isGz,
  }) async {
    Stream<List<int>> stream = file.openRead();
    if (isGz) stream = stream.transform(gzip.decoder);

    const bundlePattern = 'bundle_manifest';
    // 站点单段靠 station_code / INSERT INTO stations 认；
    // 裸 schema_meta 不算站点标记（女优/合并文件也有这张表）。
    const sitePatterns = ['station_code', 'INSERT INTO stations'];
    // 女优库身份标记：schema_meta 里的 format 值。合并库里
    // 它在文件尾部，必须全程扫（见类注释第 3 条实证）。
    const actressPattern = 'actress_library';
    const videosPatterns = ['INSERT INTO videos', 'CREATE TABLE videos'];
    const magnetPattern = "'magnet:";
    const playUrlsMarker = 'video_play_urls';
    const httpPattern = "'http";

    const tailKeep = 32; // 最长模式 20 字符，尾巴留够跨块匹配。
    // bundle 清单在合并文件第 32 字节处：只在前 8MB 查它、
    // 命中即提前返回。站点标记在单段文件头部同样提前定案；
    // 头部窗口之后才出现的站点标记只记旗、扫完按优先级定
    // （女优标记优先于它）。女优标记全程扫、不设窗口。
    const headWindowBytes = 8 * 1024 * 1024;
    var scannedBytes = 0;
    var tail = '';
    var videosSeen = false;
    var actressSeen = false;
    var siteSeen = false;
    var magnetHits = 0;
    // video_play_urls 首个样本：null=还没采到，true=magnet，
    // false=http。
    bool? playUrlSampleIsMagnet;
    var sampleBuffer = '';
    var sampleWindowOpen = false;

    await for (final chunk in stream) {
      scannedBytes += chunk.length;
      final data = tail + latin1.decode(chunk);
      if (scannedBytes <= headWindowBytes) {
        if (data.contains(bundlePattern)) {
          return UnifiedImportKind.bundle;
        }
        if (!siteSeen) {
          for (final pattern in sitePatterns) {
            if (data.contains(pattern)) return UnifiedImportKind.siteLibrary;
          }
        }
      } else if (!siteSeen) {
        for (final pattern in sitePatterns) {
          if (data.contains(pattern)) {
            siteSeen = true;
            break;
          }
        }
      }
      if (!videosSeen) {
        for (final pattern in videosPatterns) {
          if (data.contains(pattern)) {
            videosSeen = true;
            break;
          }
        }
      }
      if (!actressSeen && data.contains(actressPattern)) {
        actressSeen = true;
      }
      // 女优标记与标准表都已见：身份已定，不必再扫（合并
      // 库里标记在文件尾，走到这里基本就是扫完了）。
      if (actressSeen && videosSeen) {
        return UnifiedImportKind.actressSql;
      }
      // 磁力只计数、不提前定案：合并库的磁力段在女优标记
      // 之前，提前返回必误判（见类注释第 3 条）。
      magnetHits += magnetPattern.allMatches(data).length;
      if (playUrlSampleIsMagnet == null) {
        if (!sampleWindowOpen) {
          final markerAt = data.indexOf(playUrlsMarker);
          if (markerAt >= 0) {
            sampleWindowOpen = true;
            sampleBuffer = data.substring(markerAt + playUrlsMarker.length);
          }
        } else {
          sampleBuffer += latin1.decode(chunk);
        }
        if (sampleWindowOpen) {
          // 只在窗口内的字节里找形态：整块（64KB 级）一次
          // 追加时若按全缓冲找，窗口外的封面 http 会抢先把
          // 样本污染成 http（真磁力库实测：首个标记是建表
          // 语句、磁力地址在 83MB 外，旧找法必误判）。
          final window = sampleBuffer.length > _sampleWindowBytes
              ? sampleBuffer.substring(0, _sampleWindowBytes)
              : sampleBuffer;
          final magnetAt = window.indexOf(magnetPattern);
          final httpAt = window.indexOf(httpPattern);
          if (magnetAt >= 0 && (httpAt < 0 || magnetAt < httpAt)) {
            playUrlSampleIsMagnet = true;
          } else if (httpAt >= 0) {
            playUrlSampleIsMagnet = false;
          } else if (sampleBuffer.length >= _sampleWindowBytes) {
            // 窗口内没采到地址形态：放弃这次样本，下一个
            // video_play_urls 标记再采，计数兜底还在。
            sampleWindowOpen = false;
            sampleBuffer = '';
          }
        }
      }
      tail = data.length <= tailKeep
          ? data
          : data.substring(data.length - tailKeep);
    }

    // 扫完定案，优先级：女优标记 > 站点标记 > 标准表＋地址
    // 形态。女优标记在场即女优库（合并库形态），哪怕磁力
    // 线路成千上万条也不许落磁力路。
    if (actressSeen) return UnifiedImportKind.actressSql;
    if (siteSeen) return UnifiedImportKind.siteLibrary;
    if (!videosSeen) return UnifiedImportKind.unknown;
    // 磁力计数达决定线（25 条）→ 磁力：这条旧规则本身没
    // 错，错的是它当年排在女优标记之前提前定案；现在女优
    // 标记已在上面先判，计数定案不会再误伤合并库。样本法
    // 只管计数没到线的小文件（样本窗口可能被建表语句后
    // 的无关 http 污染，真磁力库 99,301 条不能靠样本定）。
    if (magnetHits >= magnetDecisiveHits) {
      return UnifiedImportKind.magnetSql;
    }
    if (playUrlSampleIsMagnet == true) return UnifiedImportKind.magnetSql;
    if (playUrlSampleIsMagnet == false) return UnifiedImportKind.actressSql;
    if (magnetHits > 0) return UnifiedImportKind.magnetSql;
    return UnifiedImportKind.actressSql;
  }
}
