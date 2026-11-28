// 网盘刮削 A 层适配器（xiuxian_wangpan_scrape_20261128）：
// 夹具回放各站真响应形态——JavDB 接口信封（番号精确匹配、
// 国产标题检索）、DMM cid 直链图占位过滤、豆瓣 suggest、
// R18.dev JSON。网络全部用注入夹具，不打真站。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/actress/actress_javdb_api.dart';
import 'package:fqapp/cloud_drive/pan_scrape_adapter.dart';
import 'package:fqapp/cloud_drive/pan_scrape_adapters_impl.dart';
import 'package:fqapp/cloud_drive/pan_scrape_identify.dart';
import 'package:fqapp/cloud_drive/pan_scrape_settings.dart';

PanScrapeContext _ctx(
  String name, {
  PanScrapeDeps? deps,
  PanScrapeSettings? settings,
}) => PanScrapeContext(
  identity: panIdentify(name),
  settings: settings ?? PanScrapeDefaults.settings,
  deps: deps ?? PanScrapeDeps(),
);

List<int> _pngBytes(int width, int height) => [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  13,
  0x49,
  0x48,
  0x44,
  0x52,
  (width >> 24) & 0xFF,
  (width >> 16) & 0xFF,
  (width >> 8) & 0xFF,
  width & 0xFF,
  (height >> 24) & 0xFF,
  (height >> 16) & 0xFF,
  (height >> 8) & 0xFF,
  height & 0xFF,
];

void main() {
  group('JavDB 接口适配器', () {
    JavdbApiClient fakeClient() {
      return JavdbApiClient(
        fetch: (url) async {
          if (url.contains('api/v2/search')) {
            return jsonEncode({
              'success': 1,
              'data': {
                'movies': [
                  {
                    'id': 'mX',
                    'number': 'SSIS-002',
                    'title': '相近番号不认',
                    'cover_url': 'https://pics.javdb.com/wrong.jpg',
                  },
                  {
                    'id': 'm1',
                    'number': 'SSIS-001',
                    'title': '真标题',
                    'cover_url': 'https://pics.javdb.com/c1.jpg',
                    'score': '4.5',
                    'release_date': '2024-01-01',
                    'duration': 120,
                  },
                ],
              },
            });
          }
          if (url.contains('api/v4/movies/m1')) {
            return jsonEncode({
              'success': 1,
              'data': {
                'movie': {
                  'actors': [
                    {'name': '女优甲', 'avatar_url': 'https://a/1.jpg'},
                  ],
                  'maker_name': 'S1',
                  'series_name': '某系列',
                  'score': '4.6',
                  'preview_images': [
                    {'large_url': 'https://s/1.jpg'},
                  ],
                },
              },
            });
          }
          return jsonEncode({'success': 1, 'data': {}});
        },
      );
    }

    test('番号精确相等才认：相近番号不冒充', () async {
      final adapter = PanJavdbAdapter(client: fakeClient());
      final meta = await adapter.fetch(_ctx('SSIS-001 某片.mkv'));
      expect(meta, isNotNull);
      expect(meta!.title, '真标题');
      expect(meta.cover, 'https://pics.javdb.com/c1.jpg');
      expect(meta.actresses, ['女优甲']);
      expect(meta.actressAvatars['女优甲'], 'https://a/1.jpg');
      expect(meta.maker, 'S1');
      expect(meta.series, '某系列');
      expect(meta.rating, '4.6');
      expect(meta.stills, ['https://s/1.jpg']);
      expect(meta.durationMinutes, 120);
    });

    test('国产标题检索：无番号走标题搜取首位', () async {
      final adapter = PanJavdbAdapter(
        client: JavdbApiClient(
          fetch: (url) async {
            if (url.contains('api/v2/search')) {
              return jsonEncode({
                'success': 1,
                'data': {
                  'movies': [
                    {
                      'id': 'm9',
                      'number': 'MD-0123',
                      'title': '姐姐的秘密',
                      'cover_url': 'https://pics.javdb.com/md.jpg',
                    },
                  ],
                },
              });
            }
            return jsonEncode({'success': 1, 'data': {}});
          },
        ),
      );
      final meta = await adapter.fetch(_ctx('天美传媒 姐姐的秘密.mp4'));
      expect(meta, isNotNull);
      expect(meta!.title, '姐姐的秘密');
      expect(meta.cover, 'https://pics.javdb.com/md.jpg');
    });
  });

  group('DMM 适配器（cid 直链 + 占位过滤）', () {
    test('高清 pl 图过门槛认封面、低清 ps 不认海报', () async {
      final deps = PanScrapeDeps(
        httpBytes: (url) async => url.endsWith('pl.jpg')
            ? _pngBytes(2184, 1469)
            : _pngBytes(100, 140),
      );
      final meta = await PanDmmAdapter().fetch(
        _ctx('SSIS-001 x.mkv', deps: deps),
      );
      expect(meta, isNotNull);
      expect(meta!.cover, contains('ssis00001pl.jpg'));
      expect(meta.poster, isEmpty);
    });

    test('pl 图宽 <700 视为占位：整站落空', () async {
      final deps = PanScrapeDeps(
        httpBytes: (url) async =>
            url.endsWith('pl.jpg') ? _pngBytes(300, 200) : _pngBytes(150, 210),
      );
      final meta = await PanDmmAdapter().fetch(
        _ctx('SSIS-001 x.mkv', deps: deps),
      );
      expect(meta, isNull);
    });

    test('连写 cid 型直查', () async {
      String? hitUrl;
      final deps = PanScrapeDeps(
        httpBytes: (url) async {
          hitUrl = url;
          return _pngBytes(1200, 800);
        },
      );
      final meta = await PanDmmAdapter().fetch(
        _ctx('ssni00321.mp4', deps: deps),
      );
      expect(meta, isNotNull);
      expect(hitUrl, contains('ssni00321'));
    });
  });

  group('豆瓣适配器', () {
    test('suggest JSON 解析、年份对上优先', () async {
      final deps = PanScrapeDeps(
        httpGet: (url, {headers}) async => jsonEncode([
          {
            'title': '流浪地球',
            'year': '2019',
            'img': 'https://img/1.jpg',
            'type': 'movie',
          },
          {
            'title': '流浪地球2',
            'year': '2023',
            'img': 'https://img/2.jpg',
            'type': 'movie',
          },
        ]),
      );
      final meta = await PanDoubanAdapter().fetch(
        _ctx('流浪地球2.2023.2160p.mkv', deps: deps),
      );
      expect(meta, isNotNull);
      expect(meta!.title, '流浪地球2');
      expect(meta.cover, 'https://img/2.jpg');
      expect(meta.releaseDate, '2023');
    });
  });

  group('R18.dev 适配器', () {
    test('JSON 字段防御解析', () async {
      final deps = PanScrapeDeps(
        httpGet: (url, {headers}) async {
          expect(url, contains('dvd_id=SSIS-001'));
          return jsonEncode({
            'data': {
              'title': 'R18 Title',
              'release_date': '2024-02-02',
              'runtime_mins': 130,
              'images': {
                'jacket_image_url': 'https://r18/cover.jpg',
                'poster_url': 'https://r18/poster.jpg',
              },
              'actresses': [
                {'name': 'Actress A', 'image_url': 'https://r18/a.jpg'},
              ],
              'studio': {'name': 'S1'},
            },
          });
        },
      );
      final meta = await PanR18DevAdapter().fetch(
        _ctx('SSIS-001 x.mkv', deps: deps),
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'R18 Title');
      expect(meta.cover, 'https://r18/cover.jpg');
      expect(meta.poster, 'https://r18/poster.jpg');
      expect(meta.actresses, ['Actress A']);
      expect(meta.maker, 'S1');
      expect(meta.durationMinutes, 130);
    });
  });

  group('JavDB 无水印通道改写', () {
    test('pics.javdb.com 换 tp.spfcas.com、路径不变', () {
      expect(
        javdbNoWatermarkUrl('https://pics.javdb.com/covers/abc.jpg'),
        'https://tp.spfcas.com/covers/abc.jpg',
      );
      expect(
        javdbNoWatermarkUrl('https://pics.dmm.co.jp/x.jpg'),
        'https://pics.dmm.co.jp/x.jpg',
      );
    });
  });
}
