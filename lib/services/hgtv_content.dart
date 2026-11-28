import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'hongguo_identity.dart';
import 'hongguo_sign.dart';

const String _hgtvAppBase = 'https://api5-normal-sinfonlineb.fqnovel.com';
const String _hgtvWebBase = 'https://hongguoduanju.com';

String _goQueryEscape(String value) {
  final bytes = utf8.encode(value);
  final out = StringBuffer();
  const hex = '0123456789ABCDEF';
  for (final byte in bytes) {
    if ((byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        byte == 0x2D ||
        byte == 0x5F ||
        byte == 0x2E ||
        byte == 0x7E) {
      out.writeCharCode(byte);
    } else if (byte == 0x20) {
      out.write('+');
    } else {
      out.write('%');
      out.write(hex[(byte >> 4) & 15]);
      out.write(hex[byte & 15]);
    }
  }
  return out.toString();
}

String _hgtvQueryString(Map<String, String> params) {
  final keys = params.keys.toList()..sort();
  return keys
      .map((key) => '${_goQueryEscape(key)}=${_goQueryEscape(params[key]!)}')
      .join('&');
}

String _anyString(dynamic value) {
  if (value == null) return '';
  if (value is int) return value.toString();
  if (value is double) {
    if (value == value.truncateToDouble()) return value.toInt().toString();
    return value.toString();
  }
  return value.toString().trim();
}

String _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = _anyString(map[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return const {};
}

class _HgtvCategory {
  final String id;
  final String name;
  final String genre;
  final String sort;

  const _HgtvCategory(this.id, this.name, this.genre, this.sort);
}

const List<_HgtvCategory> _hgtvCategories = [
  _HgtvCategory('home', '首页推荐', '', 'hot_score'),
  _HgtvCategory('real', '真人剧', 'short_play', 'hot_score'),
  _HgtvCategory('comic', '漫剧', 'comic_series', 'hot_score'),
  _HgtvCategory('ai', 'AI剧', 'ai_series', 'hot_score'),
  _HgtvCategory('latest', '最新上架', '', 'online_time'),
];

_HgtvCategory _hgtvCategoryFor(String categoryId) {
  switch (categoryId.trim()) {
    case '':
    case 'all':
    case 'ALL':
    case '全部':
    case 'home':
    case '首页推荐':
      return _hgtvCategories[0];
    case 'real':
    case 'short_play':
    case '真人剧':
      return _hgtvCategories[1];
    case 'comic':
    case 'comic_series':
    case '漫剧':
      return _hgtvCategories[2];
    case 'ai':
    case 'ai_series':
    case 'AI剧':
    case 'AI 剧':
      return _hgtvCategories[3];
    case 'latest':
    case 'online_time':
    case '最新上架':
      return _hgtvCategories[4];
    default:
      throw StateError('HGTV 分类无效');
  }
}

DramaSiteItem? hgtvDramaFromAny(dynamic row) {
  final map = _asMap(row);
  if (map.isEmpty) return null;
  var node = _asMap(map['video_data']);
  if (node.isEmpty) node = map;
  var id = _firstString(node, ['series_id_str', 'series_id']);
  if (id.isEmpty) id = _firstString(map, ['series_id_str', 'series_id']);
  if (id.isEmpty) id = _firstString(node, ['keyword']);
  if (id.isEmpty) id = _firstString(map, ['keyword']);
  if (!RegExp(r'^\d+$').hasMatch(id)) return null;
  var title = _firstString(node, ['series_title', 'series_name', 'title']);
  if (title.isEmpty) title = _firstString(map, ['series_name', 'name']);
  if (title.isEmpty) title = id;
  final cover = _firstString(node, ['series_cover', 'cover']);
  final coverFallback = cover.isEmpty
      ? _firstString(map, ['series_cover'])
      : cover;
  var remark = _firstString(node, ['episode_right_text']);
  if (remark.isEmpty) remark = _firstString(map, ['episode_right_text']);
  if (remark.isEmpty) {
    var count = _firstString(node, ['episode_cnt']);
    if (count.isEmpty) count = _firstString(map, ['episode_cnt']);
    if (count.isNotEmpty) remark = '共$count集';
  }
  return DramaSiteItem(
    id: id,
    title: title,
    cover: coverFallback,
    remark: remark,
  );
}

class HgtvLandpage {
  final List<DramaSiteItem> items;
  final bool hasMore;

  const HgtvLandpage(this.items, this.hasMore);
}

HgtvLandpage parseHgtvLandpage(Map<String, dynamic> decoded) {
  final data = _asMap(decoded['data']);
  final rows = data['video_data'];
  final items = <DramaSiteItem>[];
  final seen = <String>{};
  if (rows is List) {
    for (final row in rows) {
      final item = hgtvDramaFromAny(row);
      if (item == null || !seen.add(item.id)) continue;
      items.add(item);
    }
  }
  return HgtvLandpage(items, data['has_more'] == true);
}

DramaSiteDetail parseHgtvAppDetail(
  Map<String, dynamic> decoded,
  String seriesId,
) {
  final data = _asMap(decoded['data']);
  final detail = _asMap(data['video_data']);
  if (_firstString(detail, ['series_id_str', 'series_id']) != seriesId) {
    throw StateError('HGTV App 未返回所请求的剧集');
  }
  final drama = hgtvDramaFromAny(detail);
  if (drama == null) {
    throw StateError('HGTV App 未返回所请求的剧集');
  }
  final rows = detail['video_list'];
  if (rows is! List) {
    throw StateError('HGTV App 未返回完整分集');
  }
  final episodes = <DramaSiteEpisode>[];
  final indexed = <({int index, DramaSiteEpisode episode})>[];
  final seenVideo = <String>{};
  final seenIndex = <int>{};
  for (final raw in rows) {
    if (raw is! Map) continue;
    final video = _asMap(raw);
    final videoId = _firstString(video, ['vid']);
    final index = int.tryParse(_firstString(video, ['vid_index']));
    if (index == null ||
        index < 1 ||
        !RegExp(r'^\d+$').hasMatch(videoId)) {
      throw StateError('HGTV App 分集编号或视频 ID 无效');
    }
    final owner = _firstString(video, ['series_id']);
    if (owner.isNotEmpty && owner != seriesId) {
      throw StateError('HGTV App 返回了其他剧集的分集');
    }
    if (!seenVideo.add(videoId) || !seenIndex.add(index)) {
      throw StateError('HGTV App 返回了重复分集');
    }
    indexed.add((
      index: index,
      episode: DramaSiteEpisode(
        videoId: videoId,
        title: '第$index集',
        seriesId: seriesId,
      ),
    ));
  }
  indexed.sort((a, b) => a.index.compareTo(b.index));
  for (var i = 0; i < indexed.length; i++) {
    if (indexed[i].index != i + 1) {
      throw StateError('HGTV 分集列表不连续');
    }
    episodes.add(indexed[i].episode);
  }
  final total = int.tryParse(_firstString(detail, ['episode_cnt']));
  if (episodes.isEmpty || (total != null && total > episodes.length)) {
    throw StateError('HGTV App 未返回完整分集');
  }
  return DramaSiteDetail(
    id: seriesId,
    title: drama.title,
    cover: drama.cover,
    episodes: episodes,
  );
}

List<DramaSiteItem> parseHgtvSearch(Map<String, dynamic> decoded) {
  final rows = decoded['searchList'];
  final items = <DramaSiteItem>[];
  final seen = <String>{};
  if (rows is List) {
    for (final row in rows) {
      final item = hgtvDramaFromAny(row);
      if (item == null || !seen.add(item.id)) continue;
      items.add(item);
    }
  }
  return items;
}

String _hgtvDeviceId(Random random) {
  final hi = random.nextInt(1 << 32);
  final lo = random.nextInt(1 << 32);
  final combined = (hi << 32) | lo;
  final value = 1000000000000000000 + combined % 8000000000000000000;
  return value.toString();
}

class HgtvContentClient implements DramaSiteContentClient {
  final http.Client _client;

  /// 本客户端定格的匿名身份：构造时定格，整个生命周期不变——
  /// 同一轮里目录/详情/搜索与签名用的 device_id 完全一致，
  /// 轮换只发生在下一次构造（见 hongguo_identity.dart）。
  late final HongguoAnonIdentity _identity;

  /// 身份由轮换服务供给时才挂被拒标记；外部注入固定身份或旧
  /// 随机路（测试）时为 null，被拒不回写。
  final HongguoIdentityService? _identityService;

  /// 优先次序：注入身份 > 注入服务快照 > 传入 Random 的旧随机
  /// 路（仅存量测试在用）> 全局轮换服务快照。
  HgtvContentClient([
    http.Client? client,
    Random? random,
    HongguoAnonIdentity? identity,
    HongguoIdentityService? identityService,
  ]) : _client = client ?? http.Client(),
       _identityService = identity != null
           ? null
           : (identityService ??
                 (random == null ? HongguoIdentityService.shared : null)) {
    if (identity != null) {
      _identity = identity;
    } else if (identityService != null) {
      _identity = identityService.snapshot();
    } else if (random != null) {
      _identity = HongguoAnonIdentity(
        deviceId: _hgtvDeviceId(random),
        installId: _hgtvDeviceId(random),
        dateStamp: HongguoIdentityService.dateStampOf(DateTime.now()),
        ipStamp: HongguoIdentityService.unknownIp,
        generation: 0,
      );
    } else {
      _identity = HongguoIdentityService.shared.snapshot();
    }
  }

  /// 本客户端定格的身份（供页面/测试核对，播放链不回头换）。
  HongguoAnonIdentity get identity => _identity;

  Map<String, String> _appQuery() {
    final profile = _identity.profile;
    return {
      'aid': '8662',
      'app_name': 'novelread',
      'version_code': profile.versionCode,
      'version_name': profile.versionName,
      'manifest_version_code': profile.versionCode,
      'update_version_code': profile.versionCode,
      'channel': profile.channel,
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'device_type': profile.model,
      'device_brand': profile.brand,
      'language': 'zh',
      'os_api': profile.osApi,
      'os_version': profile.osVersion,
      'resolution': profile.resolution,
      'dpi': profile.dpi,
      'ac': 'wifi',
      'device_id': _identity.deviceId,
      'iid': _identity.installId,
      'host_abi': 'arm64-v8a',
      'dragon_device_type': 'phone',
      'pv_player': profile.versionCode,
      'compliance_status': '0',
      'need_personal_recommend': '1',
      'player_so_load': '1',
      'is_android_pad_screen': '0',
      'cdid': _identity.cdid,
    };
  }

  Future<Map<String, dynamic>> _appPost(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final body = utf8.encode(jsonEncode(payload));
    Object? lastError;
    // 服务端对「不够格的身份」是静默回空：200 但 body 为空。
    // 两次重试都回空 = 这套身份被拒，标记给下一次构造轮换；
    // 纯网络异常（超时/断连）不算被拒，不标记。
    var sawEmptyBody = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      final now = DateTime.now();
      final query = _appQuery()
        ..['_rticket'] = now.millisecondsSinceEpoch.toString();
      final queryString = _hgtvQueryString(query);
      final url = '$_hgtvAppBase$path?$queryString';
      final headers = hongguoPlayerHeaders(
        url: url,
        body: body,
        now: now,
        rawQuery: queryString,
      );
      headers['User-Agent'] = _identity.profile.userAgent;
      headers['Accept'] = 'application/json';
      headers['X-XS-From-Web'] = '0';
      headers['Sdk-Version'] = '2';
      headers['Content-Type'] = 'application/json; charset=utf-8';
      http.Response response;
      try {
        response = await _client
            .post(Uri.parse(url), headers: headers, body: body)
            .timeout(const Duration(seconds: 20));
      } catch (error) {
        lastError = error;
        continue;
      }
      if (response.statusCode != 200) {
        final httpError =
            StateError('红果 App 接口 HTTP ${response.statusCode}');
        lastError = httpError;
        if (response.statusCode >= 400 && response.statusCode < 500) {
          throw httpError;
        }
        continue;
      }
      final text = utf8.decode(response.bodyBytes);
      if (text.isEmpty) {
        sawEmptyBody = true;
        lastError = StateError('红果 App 接口未返回有效数据');
        continue;
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('红果 App 接口返回格式异常');
      }
      final code = _anyString(decoded['code']);
      if (code.isEmpty) {
        final baseResp = _asMap(decoded['BaseResp']);
        final alt = _anyString(baseResp['StatusCode']);
        if (alt.isNotEmpty && alt != '0') {
          await _markIdentityRejected();
          throw StateError('红果 App 接口暂不可用（$alt）');
        }
      } else if (code != '0') {
        await _markIdentityRejected();
        throw StateError('红果 App 接口暂不可用（$code）');
      }
      return decoded;
    }
    if (sawEmptyBody) await _markIdentityRejected();
    throw lastError ?? StateError('红果 App 接口未返回有效数据');
  }

  /// 身份被拒只置标记，本客户端这一轮照旧失败收尾——不在请求
  /// 链中途换身份（同轮一致），换新发生在下一次构造的校验里。
  Future<void> _markIdentityRejected() async {
    await _identityService?.markRejected();
  }

  Future<HgtvLandpage> _landpage(
    _HgtvCategory category,
    int appPage,
  ) async {
    final offset = appPage <= 1 ? 0 : (appPage - 2) * 100 + 20;
    final limit = appPage <= 1 ? 20 : 100;
    final genre = category.genre.isEmpty ? <String>[] : [category.genre];
    final payload = <String, dynamic>{
      'client_req_type': 3,
      'filter_ids': '',
      'limit': limit,
      'need_selector_panel': appPage == 1,
      'offset': offset,
      'req_scene': 'default',
      'req_type': appPage == 1 ? 'default' : 'only_content',
      'select_items': {
        'genre': genre,
        'sort': [category.sort],
      },
      'session_id': '',
    };
    final decoded = await _appPost(
      '/reading/distribution/category/landpage/v/',
      payload,
    );
    return parseHgtvLandpage(decoded);
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    return const [
      DramaSiteCategory('home', '首页推荐'),
      DramaSiteCategory('real', '真人剧'),
      DramaSiteCategory('comic', '漫剧'),
      DramaSiteCategory('ai', 'AI剧'),
      DramaSiteCategory('latest', '最新上架'),
    ];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final category = _hgtvCategoryFor(categoryId);
    final safePage = page < 1 ? 1 : page;
    final appPages = safePage == 1 ? [1, 2] : [safePage + 1];
    final items = <DramaSiteItem>[];
    final seen = <String>{};
    var hasMore = false;
    for (final appPage in appPages) {
      final landpage = await _landpage(category, appPage);
      hasMore = landpage.hasMore;
      for (final item in landpage.items) {
        if (seen.add(item.id)) items.add(item);
      }
    }
    return DramaSiteCatalogPage(items: items, hasMore: hasMore);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    if (!RegExp(r'^\d+$').hasMatch(seriesId)) {
      throw StateError('HGTV 剧集 ID 无效');
    }
    Map<String, dynamic>? decoded;
    Object? appError;
    try {
      decoded = await _appPost(
        '/novel/player/video_detail/v1/',
        {'series_id': seriesId},
      );
    } catch (error) {
      appError = error;
    }
    if (decoded != null) {
      try {
        return parseHgtvAppDetail(decoded, seriesId);
      } catch (error) {
        if (error is StateError &&
            error.message == 'HGTV App 未返回完整分集') {
          final web = await _webDetail(seriesId);
          if (web != null) return web;
        }
        rethrow;
      }
    }
    final web = await _webDetail(seriesId);
    if (web != null) return web;
    throw appError ?? StateError('HGTV App 未返回所请求的剧集');
  }

  Future<DramaSiteDetail?> _webDetail(String seriesId) async {
    try {
      return await HgtvMirrorContentClient(_client).detail(seriesId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw StateError('请输入搜索词');
    }
    final queryString = _hgtvQueryString({
      'aid': '8662',
      'page': '1',
      'query': keyword,
    });
    final response = await _client
        .get(
          Uri.parse('$_hgtvWebBase/api/search/result?$queryString'),
          headers: {
            'Referer': '$_hgtvWebBase/',
            'User-Agent': HgtvMirrorContentClient.userAgent,
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('HGTV 搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('HGTV 搜索返回了无效数据');
    }
    return parseHgtvSearch(decoded);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return HongguoContentClient(_client).playSource(episode);
  }
}
