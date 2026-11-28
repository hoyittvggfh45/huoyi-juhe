/// 网盘刮削统一元数据模型 + 字段级合并（调查口径：多站结果
/// 不是整站二选一，而是逐字段按优先级择优——Javinizer 的
/// metadata.priority、MDCx 的「逐字段择优」，见
/// xiuxian_scraper_survey_20261128 §1.2/§4.4）。
///
/// 合并规则：
/// - 标量字段（标题/封面/海报/简介/评分/发行日/系列/制作商）：
///   按设置档 fieldPriority 的站点序，取第一个给出非空值的站；
/// - 剧照 stills：**整组回退**（MDCx 口径）——按 stills 优先
///   序取第一个给出非空整组的站，不跨站混搭单张；
/// - 女优名单 actresses：按 actress 优先序取第一个非空名单；
///   头像按 actressAvatar 优先序逐名补（gFriends→JavDB）；
/// - 每个字段记来源站（fieldSources），页面与报告可查。
library;

import 'pan_scrape_settings.dart';

/// 一部作品的刮削元数据（各站适配器回同一模型，合并器产出
/// 的也是它）。空＝该站没给/没刮到，绝不编造。
class PanScrapedMeta {
  const PanScrapedMeta({
    this.title = '',
    this.originalTitle = '',
    this.cover = '',
    this.poster = '',
    this.coverNoWatermark = '',
    this.stills = const [],
    this.overview = '',
    this.actresses = const [],
    this.actressAvatars = const {},
    this.rating = '',
    this.releaseDate = '',
    this.series = '',
    this.maker = '',
    this.director = '',
    this.durationMinutes = 0,
    this.code = '',
    this.tmdbId = 0,
    this.sourceSite = '',
    this.fieldSources = const {},
  });

  final String title;
  final String originalTitle;

  /// 横版封面（DMM pl 级高清优先）。
  final String cover;

  /// 竖版海报（海报墙 5:7 卡面优先用它）。
  final String poster;

  /// JavDB 无水印原图通道（tp.spfcas.com）改写后的封面；
  /// 只在设置开启改写时有值，缺省空。
  final String coverNoWatermark;

  final List<String> stills;
  final String overview;
  final List<String> actresses;

  /// 女优名 → 头像地址。
  final Map<String, String> actressAvatars;

  /// 评分原值文本（各站口径不一，只存不译）。
  final String rating;
  final String releaseDate;
  final String series;
  final String maker;
  final String director;
  final int durationMinutes;

  /// 番号（番号型）；film 型为空。
  final String code;

  /// TMDB 编号（film 型 TMDB 命中时）。
  final int tmdbId;

  /// 本条（未合并时）出自哪站；合并后为主要来源站。
  final String sourceSite;

  /// 字段名 → 来源站 id（合并器填写）。
  final Map<String, String> fieldSources;

  /// 卡面图：竖版海报优先（设置 preferVerticalPoster），
  /// 其次横版封面。
  String displayCover({bool preferVertical = true}) {
    if (preferVertical && poster.isNotEmpty) return poster;
    if (cover.isNotEmpty) return cover;
    return poster;
  }

  /// 成功门槛（JavSP required_keys=cover,title，调查 §1.2）：
  /// 封面（横/竖任一）＋标题齐才算刮成。
  bool get isComplete =>
      title.isNotEmpty && (cover.isNotEmpty || poster.isNotEmpty);

  bool get isEmpty =>
      title.isEmpty &&
      cover.isEmpty &&
      poster.isEmpty &&
      overview.isEmpty &&
      actresses.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    'originalTitle': originalTitle,
    'cover': cover,
    'poster': poster,
    'coverNoWatermark': coverNoWatermark,
    'stills': stills,
    'overview': overview,
    'actresses': actresses,
    'actressAvatars': actressAvatars,
    'rating': rating,
    'releaseDate': releaseDate,
    'series': series,
    'maker': maker,
    'director': director,
    'durationMinutes': durationMinutes,
    'code': code,
    'tmdbId': tmdbId,
    'sourceSite': sourceSite,
    'fieldSources': fieldSources,
  };

  factory PanScrapedMeta.fromJson(Map<String, dynamic> json) {
    String s(Object? v) => v?.toString() ?? '';
    List<String> ls(Object? v) => [
      if (v is List)
        for (final e in v)
          if (e != null && e.toString().isNotEmpty) e.toString(),
    ];
    Map<String, String> ms(Object? v) => {
      if (v is Map)
        for (final e in v.entries)
          if (e.value != null && e.value.toString().isNotEmpty)
            e.key.toString(): e.value.toString(),
    };
    return PanScrapedMeta(
      title: s(json['title']),
      originalTitle: s(json['originalTitle']),
      cover: s(json['cover']),
      poster: s(json['poster']),
      coverNoWatermark: s(json['coverNoWatermark']),
      stills: ls(json['stills']),
      overview: s(json['overview']),
      actresses: ls(json['actresses']),
      actressAvatars: ms(json['actressAvatars']),
      rating: s(json['rating']),
      releaseDate: s(json['releaseDate']),
      series: s(json['series']),
      maker: s(json['maker']),
      director: s(json['director']),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
      code: s(json['code']),
      tmdbId: (json['tmdbId'] as num?)?.toInt() ?? 0,
      sourceSite: s(json['sourceSite']),
      fieldSources: ms(json['fieldSources']),
    );
  }
}

/// 字段级合并器：输入各站结果（站点 id → 元数据），按设置档
/// 优先级逐字段择优，产出合并结果（带 fieldSources 记账）。
abstract final class PanScrapeMerger {
  static PanScrapedMeta merge(
    Map<String, PanScrapedMeta> bySite,
    PanScrapeSettings settings,
  ) {
    if (bySite.isEmpty) return const PanScrapedMeta();
    final sources = <String, String>{};

    String pick(String field, String Function(PanScrapedMeta m) get) {
      for (final site in settings.priorityFor(field)) {
        final meta = bySite[site];
        if (meta == null) continue;
        final value = get(meta);
        if (value.isNotEmpty) {
          sources[field] = site;
          return value;
        }
      }
      // 优先级表没覆盖到的站（链外字段源）按 bySite 顺序兜底。
      for (final entry in bySite.entries) {
        final value = get(entry.value);
        if (value.isNotEmpty) {
          sources[field] = entry.key;
          return value;
        }
      }
      return '';
    }

    List<String> pickList(
      String field,
      List<String> Function(PanScrapedMeta m) get,
    ) {
      for (final site in settings.priorityFor(field)) {
        final meta = bySite[site];
        if (meta == null) continue;
        final value = get(meta);
        if (value.isNotEmpty) {
          sources[field] = site;
          return value;
        }
      }
      for (final entry in bySite.entries) {
        final value = get(entry.value);
        if (value.isNotEmpty) {
          sources[field] = entry.key;
          return value;
        }
      }
      return const [];
    }

    final title = pick('title', (m) => m.title);
    final cover = pick('cover', (m) => m.cover);
    final poster = pick('poster', (m) => m.poster);
    final overview = pick('overview', (m) => m.overview);
    final rating = pick('rating', (m) => m.rating);
    final releaseDate = pick('releaseDate', (m) => m.releaseDate);
    final series = pick('series', (m) => m.series);
    final maker = pick('maker', (m) => m.maker);
    // 剧照整组回退：pickList 天然整组取一个站，正合口径。
    final stills = pickList('stills', (m) => m.stills);
    final actresses = pickList('actress', (m) => m.actresses);

    // 头像逐名按 actressAvatar 优先序补：先到先得、后站只补缺。
    final avatars = <String, String>{};
    for (final site in settings.priorityFor('actressAvatar')) {
      final meta = bySite[site];
      if (meta == null) continue;
      for (final name in actresses) {
        final url = meta.actressAvatars[name];
        if (url != null && url.isNotEmpty && !avatars.containsKey(name)) {
          avatars[name] = url;
          sources['actressAvatar'] = site;
        }
      }
    }
    for (final entry in bySite.entries) {
      for (final name in actresses) {
        final url = entry.value.actressAvatars[name];
        if (url != null && url.isNotEmpty && !avatars.containsKey(name)) {
          avatars[name] = url;
        }
      }
    }

    var duration = 0;
    var tmdbId = 0;
    var code = '';
    var originalTitle = '';
    var director = '';
    var coverNoWatermark = '';
    for (final meta in bySite.values) {
      if (duration == 0 && meta.durationMinutes > 0) {
        duration = meta.durationMinutes;
      }
      if (tmdbId == 0 && meta.tmdbId > 0) tmdbId = meta.tmdbId;
      if (code.isEmpty && meta.code.isNotEmpty) code = meta.code;
      if (originalTitle.isEmpty && meta.originalTitle.isNotEmpty) {
        originalTitle = meta.originalTitle;
      }
      if (director.isEmpty && meta.director.isNotEmpty) {
        director = meta.director;
      }
      if (coverNoWatermark.isEmpty && meta.coverNoWatermark.isNotEmpty) {
        coverNoWatermark = meta.coverNoWatermark;
      }
    }

    return PanScrapedMeta(
      title: title,
      originalTitle: originalTitle,
      cover: cover,
      poster: poster,
      coverNoWatermark: coverNoWatermark,
      stills: stills,
      overview: overview,
      actresses: actresses,
      actressAvatars: avatars,
      rating: rating,
      releaseDate: releaseDate,
      series: series,
      maker: maker,
      director: director,
      durationMinutes: duration,
      code: code,
      tmdbId: tmdbId,
      sourceSite: sources['cover'] ?? sources['title'] ?? '',
      fieldSources: sources,
    );
  }
}
