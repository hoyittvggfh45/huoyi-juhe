// 红果（hongguoduanju.com 网页端）真网探针：分类→详情→取流→CDN 三态验播。
//
// 默认跳过，只跑真网时显式跑：
//   flutter test test/hongguo_live_probe_test.dart --run-skipped
// 2026-11-28 审计时立：站方把 vid 换成 v1_ 令牌、详情只带可看集数、
// 搜索页去掉 SSR 数据，全链曾断在详情解析；修复后本探针全链通过
// （分类 24 条/页、搜索 10 条、详情 5 集、取流回 CDN 正片 206）。
// 失败只代表当次出口/站方状态，报错信息里会写清卡在哪一步。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/drama_site_content.dart';

const _ua = HgtvMirrorContentClient.userAgent;
const _base = 'https://hongguoduanju.com';
const _liveSkip = 'live network probe: run with --run-skipped';

void _p(String msg) {
  // ignore: avoid_print
  print('PROBE $msg');
}

Future<void> _headRange(String label, String url, Map<String, String> headers) async {
  try {
    final resp = await http
        .get(Uri.parse(url), headers: {'Range': 'bytes=0-1023', ...headers})
        .timeout(const Duration(seconds: 30));
    final cr = resp.headers['content-range'] ?? '';
    final cl = resp.headers['content-length'] ?? '';
    final ct = resp.headers['content-type'] ?? '';
    _p('$label -> ${resp.statusCode} type=$ct len=$cl range=$cr bytes=${resp.bodyBytes.length}');
  } catch (e) {
    _p('$label -> EXCEPTION $e');
  }
}

void main() {
  test('hongguo live chain probe', () async {
    final client = HongguoContentClient();

    // 1) 分类目录
    for (final cat in ['all', 'real-drama', 'comic-drama']) {
      try {
        final page = await client.catalog(cat, 1);
        _p('catalog($cat,1) items=${page.items.length} hasMore=${page.hasMore} topics=${page.topics.length}');
        if (page.items.isNotEmpty) {
          _p('catalog($cat,1) first id=${page.items.first.id} title=${page.items.first.title} remark=${page.items.first.remark}');
        }
      } catch (e) {
        _p('catalog($cat,1) EXCEPTION $e');
      }
    }
    try {
      final p2 = await client.catalog('real-drama', 2);
      _p('catalog(real-drama,2) items=${p2.items.length} first=${p2.items.isEmpty ? '-' : p2.items.first.id}');
    } catch (e) {
      _p('catalog(real-drama,2) EXCEPTION $e');
    }

    // 取一个真实 series
    final home = await client.catalog('real-drama', 1);
    expect(home.items, isNotEmpty, reason: '分类为空，后续环无从验');
    final seriesId = home.items.first.id;
    _p('series under test: $seriesId ${home.items.first.title}');

    // 2) 搜索
    try {
      final results = await client.search(home.items.first.title.substring(0, 2));
      _p('search(2字) items=${results.length}');
    } catch (e) {
      _p('search EXCEPTION $e');
    }

    // 3) 详情
    final detail = await client.detail(seriesId);
    _p('detail title=${detail.title} episodes=${detail.episodes.length}');
    expect(detail.episodes, isNotEmpty);
    final ep = detail.episodes.first;
    _p('episode1 videoId=${ep.videoId}');

    final episode = DramaSiteEpisode(
      videoId: ep.videoId,
      title: ep.title,
      seriesId: seriesId,
    );

    // 4) 播放页原文检查
    try {
      final resp = await http.get(
        Uri.parse('$_base/player/$seriesId/${ep.videoId}'),
        headers: {'Referer': '$_base/', 'User-Agent': _ua},
      ).timeout(const Duration(seconds: 30));
      _p('player page status=${resp.statusCode} bytes=${resp.bodyBytes.length}');
      final addrs = HongguoContentClient.parsePlayerAddresses(resp.body);
      _p('player page parsePlayerAddresses=${addrs.length} $addrs');
      _p('player page has video_player_info=${resp.body.contains('video_player_info')} has protectedPlayback=${resp.body.contains('protectedPlayback')}');
    } catch (e) {
      _p('player page EXCEPTION $e');
    }

    // 5) fallback-play-info 原文
    String? rawMainUrl;
    try {
      final resp = await http.post(
        Uri.parse('$_base/api/video/protected/fallback-play-info?aid=8662'),
        headers: {
          'Referer': '$_base/player',
          'Content-Type': 'application/json; charset=utf-8',
          'User-Agent': _ua,
        },
        body: jsonEncode({'item_id': ep.videoId}),
      ).timeout(const Duration(seconds: 30));
      _p('fallback-play-info status=${resp.statusCode} body[0..400]=${resp.body.substring(0, resp.body.length > 400 ? 400 : resp.body.length)}');
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map) rawMainUrl = decoded['main_url']?.toString();
      }
    } catch (e) {
      _p('fallback-play-info EXCEPTION $e');
    }

    // 6) 真 playSource
    final source = await client.playSource(episode);
    _p('playSource url=${source.url}');
    _p('playSource headers=${source.headers} variants=${source.variants.map((v) => '${v.name}:${v.url}').toList()}');
    final is360 = source.url.contains('/video/public/') && source.url.contains('360p.mp4');
    _p('playSource fell back to 360p public? $is360 ; rawMainUrl same? ${rawMainUrl != null && rawMainUrl == source.url}');

    // 7) CDN 三态验播（对 playSource 给出的主地址）
    final host = Uri.tryParse(source.url)?.host ?? '';
    _p('main url host=$host');
    await _headRange('CDN no-headers', source.url, const {});
    await _headRange('CDN ua-only', source.url, const {'User-Agent': _ua});
    await _headRange('CDN ua+referer', source.url, const {
      'User-Agent': _ua,
      'Referer': '$_base/',
    });

    // 8) 360p 公开地址大小（判断是不是 10 秒预告）
    final u360 = '$_base/video/public/${ep.videoId}/360p.mp4';
    await _headRange('360p no-headers', u360, const {});
  }, timeout: const Timeout(Duration(minutes: 5)), skip: _liveSkip);
}
