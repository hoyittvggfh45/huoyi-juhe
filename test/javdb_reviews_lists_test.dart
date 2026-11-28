// JavDB 评论与相关清单（数据层，2026-11-28）：总管本机实拉
// 验证的真实形态 JSON——评论 GET api/v1/movies/{id}/reviews
// （信封 data.reviews，每页 10 条、默认按 likes_count 热门序）、
// 相关清单 GET api/v1/lists/related?movie_id={id}（信封
// data.lists）。只验解析、磁力抽链与失败回空，不真连网。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_javdb_api.dart';

String _envelope(Object? data) => jsonEncode({'success': 1, 'data': data});

const _fpreMagnet =
    'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';

void main() {
  group('评论解析（FPRE-249 实拉形态）', () {
    test('第 1 条热门评论字段全对、正文磁力可抽出', () async {
      String? seenUrl;
      final client = JavdbApiClient(
        fetch: (url) async {
          seenUrl = url;
          return _envelope({
            'reviews': [
              {
                'id': 101,
                'user_id': 9001,
                'username': 'snoopy419',
                'watched_count': 12,
                'status': 1,
                'status_title': '看過',
                'score': 5,
                'content': _fpreMagnet,
                'likes_count': 99,
                'liked': false,
                'created_at': '2024-05-01T08:30:00.000Z',
              },
              {
                'id': 102,
                'username': 'second_user',
                'status_title': '想看',
                'score': 0,
                'content': '不錯',
                'likes_count': 12,
                'created_at': '2024-05-02T09:00:00.000Z',
              },
            ],
          });
        },
      );
      final reviews = await client.movieReviews('wKm94b');
      expect(seenUrl, contains('api/v1/movies/wKm94b/reviews?page=1'));
      expect(reviews, hasLength(2));
      final first = reviews.first;
      expect(first.id, 101);
      expect(first.username, 'snoopy419');
      expect(first.score, 5.0);
      expect(first.likesCount, 99);
      expect(first.statusTitle, '看過');
      expect(first.createdAt, '2024-05-01T08:30:00.000Z');
      expect(first.content, _fpreMagnet);
      expect(javdbMagnetLinksIn(first.content), [_fpreMagnet]);
      // score=0 表示未评分，照原值回。
      expect(reviews[1].score, 0.0);
    });

    test('翻页参数透传、缺失字段给安全默认值', () async {
      String? seenUrl;
      final client = JavdbApiClient(
        fetch: (url) async {
          seenUrl = url;
          return _envelope({
            'reviews': [
              {'id': '103'},
            ],
          });
        },
      );
      final reviews = await client.movieReviews('wKm94b', page: 2);
      expect(seenUrl, contains('reviews?page=2'));
      final only = reviews.single;
      expect(only.id, 103);
      expect(only.username, '');
      expect(only.score, 0.0);
      expect(only.content, '');
      expect(only.likesCount, 0);
      expect(only.createdAt, '');
      expect(only.statusTitle, '');
    });
  });

  group('javdbMagnetLinksIn', () {
    test('正文夹磁力：抽到空白为止、剥尾部标点、多条全抽', () {
      const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final text =
          '分享 magnet:?xt=urn:btih:$hashA&dn=x 好片，'
          '另一条 magnet:?xt=urn:btih:$hashB。';
      expect(javdbMagnetLinksIn(text), [
        'magnet:?xt=urn:btih:$hashA&dn=x',
        'magnet:?xt=urn:btih:$hashB',
      ]);
    });

    test('无磁力回空表', () {
      expect(javdbMagnetLinksIn('普通评论，没有链接'), isEmpty);
      expect(javdbMagnetLinksIn(''), isEmpty);
    });
  });

  group('相关清单解析（实拉形态）', () {
    test('name/movies_count 等元数据全对、description null 转空串', () async {
      String? seenUrl;
      final client = JavdbApiClient(
        fetch: (url) async {
          seenUrl = url;
          return _envelope({
            'lists': [
              {
                'id': '5ED8p8',
                'name': '精選清單',
                'description': null,
                'movies_count': 42,
                'views_count': 12345,
                'collections_count': 67,
                'is_default': false,
                'share_info': 'share-token',
                'created_at': '2023-01-15T10:00:00.000Z',
              },
              {
                'id': 'AbC123',
                'name': '第二份清單',
                'description': '說明文字',
                'movies_count': '18',
                'views_count': 100,
                'collections_count': 3,
                'created_at': '2023-02-01T10:00:00.000Z',
              },
            ],
          });
        },
      );
      final lists = await client.movieRelatedLists('wKm94b');
      expect(seenUrl, contains('api/v1/lists/related?movie_id=wKm94b'));
      expect(lists, hasLength(2));
      final first = lists.first;
      expect(first.id, '5ED8p8');
      expect(first.name, '精選清單');
      expect(first.description, '');
      expect(first.moviesCount, 42);
      expect(first.viewsCount, 12345);
      expect(first.collectionsCount, 67);
      expect(first.shareInfo, 'share-token');
      expect(first.createdAt, '2023-01-15T10:00:00.000Z');
      expect(lists[1].description, '說明文字');
      // 数值字符串混型宽容解析（照 JavdbMagnet 风格）。
      expect(lists[1].moviesCount, 18);
      expect(lists[1].shareInfo, '');
    });
  });

  group('失败/无数据回空表（不抛错）', () {
    test('空 data 回空表', () async {
      final reviewsClient = JavdbApiClient(
        fetch: (url) async => _envelope(<String, Object?>{}),
      );
      expect(await reviewsClient.movieReviews('wKm94b'), isEmpty);
      final listsClient = JavdbApiClient(
        fetch: (url) async => _envelope(null),
      );
      expect(await listsClient.movieRelatedLists('wKm94b'), isEmpty);
    });

    test('fetch 抛错回空表', () async {
      final client = JavdbApiClient(
        fetch: (url) async => throw Exception('network down'),
      );
      expect(await client.movieReviews('wKm94b'), isEmpty);
      expect(await client.movieRelatedLists('wKm94b'), isEmpty);
    });
  });
}
