/// 网盘刮削 A 层适配器取数实现（规格表在
/// pan_scrape_adapter.dart）。每个适配器：查不到/失败回
/// null 或残缺元数据，绝不编造；番号型一律番号精确相等
/// 才认（与既有番号封面链同一口径），标题检索型（国产）
/// 取搜索首位并在报告口径里注明。
library;

import '../actress/actress_database.dart';
import '../actress/actress_film_library.dart';
import '../actress/actress_javdb_api.dart';
import '../actress/actress_json_fallback.dart';
import '../tmdb/tmdb_service.dart';
import 'pan_scrape_adapter.dart';
import 'pan_scrape_identify.dart';
import 'pan_scrape_models.dart';

/// 本地女优库适配器：零网络，entriesForCodes 按番号直查，
/// 行字段全量映射（封面/标题/女优/简介/日期/头像）。
class PanLocalAdapter extends PanScrapeAdapter {
  PanLocalAdapter({FilmLibraryService? filmLibrary})
    : _filmLibrary = filmLibrary;

  FilmLibraryService? _filmLibrary;
  FilmLibraryService get _film => _filmLibrary ??= FilmLibraryService(
    database: SqfliteActressDatabase.instance,
  );

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['local']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    if (code == null || code.isEmpty) return null;
    final List<ActressJsonEntry> entries;
    final injected = ctx.deps.localLookup;
    try {
      entries = injected != null
          ? await injected(code)
          : await _film.entriesForCodes([code]);
    } catch (_) {
      return null;
    }
    final slug = filmSlugCode(code);
    for (final entry in entries) {
      if (filmSlugCode(entry.vodId) != slug &&
          filmSlugCode(entry.vodCode) != slug) {
        continue;
      }
      final actresses = [
        for (final name in entry.vodActor.split(RegExp(r'[,，、/]')))
          if (name.trim().isNotEmpty) name.trim(),
      ];
      return PanScrapedMeta(
        title: entry.vodName,
        cover: entry.vodPic,
        poster: entry.vodPic,
        overview: entry.vodContent,
        actresses: actresses,
        actressAvatars: {
          if (actresses.length == 1 && entry.vodActressPic.isNotEmpty)
            actresses.single: entry.vodActressPic,
        },
        releaseDate: entry.vodPubdate.isNotEmpty
            ? entry.vodPubdate
            : entry.vodYear,
        director: entry.vodDirector,
        code: code,
        sourceSite: 'local',
      );
    }
    return null;
  }
}

/// JavDB 接口适配器（App 接口逆向签名，免 CF 通道）：
/// 番号型走番号精确匹配＋详情补全；国产型走标题检索取
/// 首位（标题检索口径，见类注释与报告）。
class PanJavdbAdapter extends PanScrapeAdapter {
  PanJavdbAdapter({JavdbApiClient? client}) : _client = client;

  JavdbApiClient? _client;
  JavdbApiClient get _api => _client ??= JavdbApiClient();

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['javdb']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final client = ctx.deps.javdbClientFactory?.call() ?? _api;
    final identity = ctx.identity;
    try {
      if (identity.kind == PanScrapeKind.domestic) {
        return await _fetchByTitle(client, ctx);
      }
      final code = identity.code;
      if (code == null || code.isEmpty) return null;
      final movies = await client.searchMovies(code);
      final wanted = code.trim().toUpperCase();
      JavdbMovie? hit;
      for (final movie in movies) {
        if (movie.number.trim().toUpperCase() == wanted) {
          hit = movie;
          break;
        }
      }
      if (hit == null) return null;
      return await _toMeta(client, hit, ctx, code: code);
    } catch (_) {
      return null;
    }
  }

  Future<PanScrapedMeta?> _fetchByTitle(
    JavdbApiClient client,
    PanScrapeContext ctx,
  ) async {
    final parsed = ctx.identity.parsed;
    final query = (parsed?.searchTitle ?? '').trim();
    if (query.isEmpty) return null;
    try {
      final movies = await client.searchMovies(query);
      if (movies.isEmpty) return null;
      // 标题检索取首位：国产标题在 JavDB 命中率有限，取到
      // 什么摆什么，标题以接口回的为准（页面会同时保留原
      // 文件名在副题区，不冒充精确匹配）。
      return await _toMeta(client, movies.first, ctx, code: '');
    } catch (_) {
      return null;
    }
  }

  Future<PanScrapedMeta> _toMeta(
    JavdbApiClient client,
    JavdbMovie movie,
    PanScrapeContext ctx, {
    required String code,
  }) async {
    var extra = const JavdbMovieExtra();
    try {
      extra = await client.movieExtra(movie.id);
    } catch (_) {
      // 详情补不到就用搜索行字段，不整条放弃。
    }
    final poster = extra.poster.isNotEmpty ? extra.poster : movie.poster;
    final actresses = [for (final a in extra.actors) a.name];
    final info = {for (final (k, v) in extra.extraInfo) k: v};
    return PanScrapedMeta(
      title: movie.title,
      originalTitle: extra.originTitle,
      cover: poster,
      poster: poster,
      coverNoWatermark: ctx.settings.javdbImageCdnRewrite
          ? javdbNoWatermarkUrl(poster)
          : '',
      stills: extra.stills.isNotEmpty ? extra.stills : movie.previewImages,
      actresses: actresses,
      actressAvatars: {
        for (final a in extra.actors)
          if (a.avatarUrl.isNotEmpty) a.name: a.avatarUrl,
      },
      rating: extra.score.isNotEmpty ? extra.score : movie.score,
      releaseDate: movie.releaseDate,
      series: info['系列'] ?? '',
      maker: info['制作商'] ?? '',
      director: info['导演'] ?? '',
      durationMinutes: movie.durationMinutes,
      code: code.isNotEmpty ? code : movie.number,
      sourceSite: 'javdb',
    );
  }
}

/// DMM 适配器：番号→cid 换算后走官方图床直链（pl 横版/
/// ps 竖版），拉图头验尺寸——宽 < 700 视为占位图过滤掉
/// （MDCx 口径，调查 §3.3）。本机已实证 pics.dmm.co.jp
/// 直链可达（SSIS-001 → ssis00001pl.jpg 回 200）。
/// DMM 详情页解析需日本 IP 环境，本层只给图与 cid，不给
/// 文字字段（标题等由链上其他站补），不假装全字段。
class PanDmmAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['dmm']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final identity = ctx.identity;
    final cid =
        identity.cid ??
        (identity.code != null ? dmmCidForCode(identity.code!) : null);
    if (cid == null || cid.isEmpty) return null;
    final coverUrl = dmmCoverUrl(cid);
    final posterUrl = dmmPosterUrl(cid);
    var cover = '';
    var poster = '';
    try {
      final coverBytes = await ctx.deps.bytes(coverUrl);
      final size = panImageSizeOf(coverBytes);
      if (size != null && size.width >= panMinRealCoverWidth) {
        cover = coverUrl;
      }
    } catch (_) {
      // 直链不通/图不存在：落空走下一站。
    }
    try {
      final posterBytes = await ctx.deps.bytes(posterUrl);
      final size = panImageSizeOf(posterBytes);
      if (size != null && size.width >= 200) {
        poster = posterUrl;
      }
    } catch (_) {}
    if (cover.isEmpty && poster.isEmpty) return null;
    return PanScrapedMeta(
      cover: cover,
      poster: poster,
      code: identity.code ?? '',
      sourceSite: 'dmm',
    );
  }
}

/// R18.dev 接口适配器（DMM 系 JSON API 化镜像，免 CF）：
/// dvd_id 直查，字段按其 JSON 结构防御式解析。
class PanR18DevAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['r18dev']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    final String url;
    if (code != null && code.isNotEmpty) {
      url =
          'https://r18.dev/videos/vod/movies/detail/-/dvd_id='
          '${Uri.encodeComponent(code)}/json';
    } else if (ctx.identity.cid != null) {
      url =
          'https://r18.dev/videos/vod/movies/detail/-/combined='
          '${Uri.encodeComponent(ctx.identity.cid!)}/json';
    } else {
      return null;
    }
    try {
      final body = await ctx.deps.get(url);
      final data = panJsonMap(panJsonMap(panDecodeJson(body))?['data']);
      if (data == null) return null;
      final images = panJsonMap(data['images']);
      final actresses = <String>[];
      final avatars = <String, String>{};
      for (final raw in panJsonList(data['actresses'])) {
        final actor = panJsonMap(raw);
        if (actor == null) continue;
        final name = panJsonStr(actor['name']);
        if (name.isEmpty) continue;
        actresses.add(name);
        final image = panJsonStr(actor['image_url']);
        if (image.isNotEmpty) avatars[name] = image;
      }
      return PanScrapedMeta(
        title: panJsonStr(data['title']),
        cover: panJsonStr(images?['jacket_image_url']),
        poster: panJsonStr(images?['poster_url']),
        overview: panJsonStr(data['comment']),
        actresses: actresses,
        actressAvatars: avatars,
        releaseDate: panJsonStr(data['release_date']),
        series: panJsonStr(panJsonMap(data['series'])?['name']),
        maker: panJsonStr(panJsonMap(data['studio'])?['name']),
        director: panJsonStr(panJsonMap(data['director'])?['name']),
        durationMinutes: int.tryParse(panJsonStr(data['runtime_mins'])) ?? 0,
        code: code ?? '',
        sourceSite: 'r18dev',
      );
    } catch (_) {
      return null;
    }
  }
}

/// JavBus 网页适配器：详情页正则轻解析（标题 h3、封面
/// bigImage、女优 star-name、信息行日期/系列/制作商）。
class PanJavbusAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['javbus']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    if (code == null || code.isEmpty) return null;
    try {
      final html = await ctx.deps.get('https://www.javbus.com/$code');
      final title = panHtmlAttr(html, r'<h3>(.*?)</h3>');
      if (title.isEmpty) return null;
      final cover = panHtmlAttr(
        html,
        r'class="bigImage"[^>]*>\s*<img[^>]*src="([^"]+)"',
      );
      final actresses = panHtmlAll(html, r'class="star-name"[^>]*>([^<]+)</a>');
      final stills = panHtmlAll(html, r'class="sample-box"[^>]*href="([^"]+)"');
      return PanScrapedMeta(
        title: title.replaceFirst(RegExp(r'^\S+\s+'), ''),
        cover: cover,
        poster: cover,
        stills: stills,
        actresses: actresses,
        releaseDate: panHtmlAttr(html, r'發行日期:</span>\s*([\d-]+)'),
        series: panHtmlAttr(html, r'系列:</span>\s*<a[^>]*>([^<]+)</a>'),
        maker: panHtmlAttr(html, r'製作商:</span>\s*<a[^>]*>([^<]+)</a>'),
        code: code,
        sourceSite: 'javbus',
      );
    } catch (_) {
      return null;
    }
  }
}

/// JavLibrary 网页适配器：按番号搜索直达详情页，解析
/// video_jacket 封面、video_cast 女优、video_date 日期。
class PanJavlibraryAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['javlibrary']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    if (code == null || code.isEmpty) return null;
    try {
      final html = await ctx.deps.get(
        'http://www.javlibrary.com/cn/vl_searchbyid.php?keyword=$code',
      );
      final cover = panHtmlAttr(
        html,
        r'id="video_jacket_img"[^>]*src="([^"]+)"',
      );
      final title = panHtmlAttr(
        html,
        r'id="video_title"[^>]*>\s*<h3[^>]*>([^<]+)</h3>',
      );
      if (cover.isEmpty && title.isEmpty) return null;
      return PanScrapedMeta(
        title: title.replaceFirst(RegExp(r'^\S+\s+'), ''),
        cover: cover.startsWith('//') ? 'https:$cover' : cover,
        poster: cover.startsWith('//') ? 'https:$cover' : cover,
        actresses: panHtmlAll(
          html,
          r'class="star"[^>]*>\s*<a[^>]*>([^<]+)</a>',
        ),
        releaseDate: panHtmlAttr(
          html,
          r'id="video_date"[^>]*>.*?<td[^>]*>([\d-]+)</td>',
        ),
        code: code,
        sourceSite: 'javlibrary',
      );
    } catch (_) {
      return null;
    }
  }
}

/// AVSOX 网页适配器（无码专站）：搜索页取首条详情链再进
/// 详情页解析。镜像 avsox.click 本机超时未通，标未验。
class PanAvsoxAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['avsox']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code;
    if (code == null || code.isEmpty) return null;
    try {
      final search = await ctx.deps.get(
        'https://avsox.click/cn/search/${Uri.encodeComponent(code)}',
      );
      final detailPath = panHtmlAttr(
        search,
        r'href="(https://avsox\.click/cn/movie/[a-z0-9]+)"',
      );
      if (detailPath.isEmpty) return null;
      final html = await ctx.deps.get(detailPath);
      final cover = panHtmlAttr(
        html,
        r'<img[^>]*src="([^"]+)"[^>]*title="[^"]*"',
      );
      final title = panHtmlAttr(html, r'<h3>(.*?)</h3>');
      if (title.isEmpty && cover.isEmpty) return null;
      return PanScrapedMeta(
        title: title,
        cover: cover,
        poster: cover,
        actresses: panHtmlAll(html, r'/cn/star/[a-z0-9]+"[^>]*>([^<]+)</a>'),
        code: code,
        sourceSite: 'avsox',
      );
    } catch (_) {
      return null;
    }
  }
}

/// FC2PPVDB 网页适配器：FC2 数字 id 直达文章页解析。
class PanFc2ppvdbAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['fc2ppvdb']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final code = ctx.identity.code ?? '';
    final digits = RegExp(r'(\d{5,7})').firstMatch(code)?.group(1);
    if (digits == null) return null;
    try {
      final html = await ctx.deps.get('https://fc2ppvdb.com/articles/$digits');
      final title = panHtmlAttr(html, r'<title>([^<]+)</title>');
      final cover = panHtmlAttr(
        html,
        r'property="og:image"[^>]*content="([^"]+)"',
      );
      if (title.isEmpty && cover.isEmpty) return null;
      return PanScrapedMeta(
        title: title.replaceAll(RegExp(r'\s*[-|].*$'), ''),
        cover: cover,
        poster: cover,
        code: code,
        sourceSite: 'fc2ppvdb',
      );
    } catch (_) {
      return null;
    }
  }
}

/// TMDB 适配器（普通影视主查）：走既有 TmdbService。
class PanTmdbAdapter extends PanScrapeAdapter {
  PanTmdbAdapter({TmdbService? service}) : _service = service;

  TmdbService? _service;
  TmdbService get _tmdb => _service ??= TmdbService.instance;

  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['tmdb']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final parsed = ctx.identity.parsed;
    if (parsed == null || parsed.searchTitle.isEmpty) return null;
    try {
      final meta = ctx.deps.tmdbFetch != null
          ? await ctx.deps.tmdbFetch!(
              title: parsed.searchTitle,
              year: parsed.year,
            )
          : await _tmdb.fetchMetadata(
              title: parsed.searchTitle,
              year: parsed.year,
            );
      if (meta == null) return null;
      final config = ctx.deps.tmdbConfig;
      return PanScrapedMeta(
        title: meta.title,
        originalTitle: meta.originalTitle,
        cover: meta.backdropUrl(config),
        poster: meta.posterUrl(config),
        overview: meta.overview,
        actresses: [for (final c in meta.cast) c.name],
        rating: meta.voteAverage?.toString() ?? '',
        releaseDate: meta.year,
        tmdbId: meta.tmdbId,
        sourceSite: 'tmdb',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 豆瓣适配器：subject_suggest 公开 JSON 接口（本机实拉
/// 200）。按片名搜、年份对上优先。
class PanDoubanAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['douban']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final parsed = ctx.identity.parsed;
    if (parsed == null || parsed.searchTitle.isEmpty) return null;
    try {
      final body = await ctx.deps.get(
        'https://movie.douban.com/j/subject_suggest?q='
        '${Uri.encodeComponent(parsed.searchTitle)}',
      );
      final list = panJsonList(panDecodeJson(body));
      Map<String, dynamic>? best;
      for (final raw in list) {
        final item = panJsonMap(raw);
        if (item == null) continue;
        best ??= item;
        if (parsed.year != null && panJsonStr(item['year']) == parsed.year) {
          best = item;
          break;
        }
      }
      if (best == null) return null;
      return PanScrapedMeta(
        title: panJsonStr(best['title']),
        cover: panJsonStr(best['img']),
        poster: panJsonStr(best['img']),
        releaseDate: panJsonStr(best['year']),
        sourceSite: 'douban',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Bangumi 适配器：api.bgm.tv 搜索接口（type=2 动画/
/// 剧集类），中文影视与动漫回退。
class PanBangumiAdapter extends PanScrapeAdapter {
  @override
  PanScrapeSiteSpec get spec => panScrapeSiteSpecs['bangumi']!;

  @override
  Future<PanScrapedMeta?> fetch(PanScrapeContext ctx) async {
    final parsed = ctx.identity.parsed;
    if (parsed == null || parsed.searchTitle.isEmpty) return null;
    try {
      final body = await ctx.deps.get(
        'https://api.bgm.tv/search/subject/'
        '${Uri.encodeComponent(parsed.searchTitle)}'
        '?type=2&responseGroup=small',
      );
      final root = panJsonMap(panDecodeJson(body));
      final list = panJsonList(root?['list']);
      if (list.isEmpty) return null;
      final item = panJsonMap(list.first);
      if (item == null) return null;
      final images = panJsonMap(item['images']);
      final rating = panJsonMap(item['rating']);
      final nameCn = panJsonStr(item['name_cn']);
      return PanScrapedMeta(
        title: nameCn.isNotEmpty ? nameCn : panJsonStr(item['name']),
        originalTitle: panJsonStr(item['name']),
        cover: panJsonStr(images?['large'] ?? images?['common']),
        poster: panJsonStr(images?['large'] ?? images?['common']),
        overview: panJsonStr(item['summary']),
        rating: rating == null ? '' : panJsonStr(rating['score']),
        releaseDate: panJsonStr(item['air_date']),
        sourceSite: 'bangumi',
      );
    } catch (_) {
      return null;
    }
  }
}

/// gFriends 头像源（不进作品链）：按女优名查 GitHub 头像
/// 仓索引。索引形态未实证，失败静默回空——头像缺失不影响
/// 刮削成败。
class PanGfriendsAvatarSource {
  PanGfriendsAvatarSource({this.indexUrl = defaultIndexUrl});

  /// gFriends 仓库文件名索引（公开仓 gfriends/gfriends）。
  static const defaultIndexUrl =
      'https://raw.githubusercontent.com/gfriends/gfriends/master/FileNames/All.json';

  final String indexUrl;
  Map<String, String>? _index;

  Future<String> avatarFor(String name, PanScrapeDeps deps) async {
    try {
      _index ??= await _loadIndex(deps);
      return _index?[name] ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, String>> _loadIndex(PanScrapeDeps deps) async {
    final body = await deps.get(indexUrl);
    final decoded = panDecodeJson(body);
    final out = <String, String>{};
    if (decoded is Map) {
      for (final entry in decoded.entries) {
        out[entry.key.toString()] =
            'https://raw.githubusercontent.com/gfriends/gfriends/master/'
            'Content/${entry.value}';
      }
    }
    return out;
  }
}

/// 组装适配器表：A 层真实现，其余 MDCx 站与 thejavdb 走
/// B 层登记（规格在、取数未实现、恒落空）。
Map<String, PanScrapeAdapter> panBuildAdapters() {
  final adapters = <String, PanScrapeAdapter>{
    'local': PanLocalAdapter(),
    'javdb': PanJavdbAdapter(),
    'dmm': PanDmmAdapter(),
    'r18dev': PanR18DevAdapter(),
    'javbus': PanJavbusAdapter(),
    'javlibrary': PanJavlibraryAdapter(),
    'avsox': PanAvsoxAdapter(),
    'fc2ppvdb': PanFc2ppvdbAdapter(),
    'tmdb': PanTmdbAdapter(),
    'douban': PanDoubanAdapter(),
    'bangumi': PanBangumiAdapter(),
  };
  for (final spec in panScrapeSiteSpecs.values) {
    adapters.putIfAbsent(spec.id, () => PanSpecOnlyAdapter(spec));
  }
  return adapters;
}
