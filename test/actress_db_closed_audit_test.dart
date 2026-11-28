// 女优库 database_closed 自查批测试（2026-11-28）：
//
// 火蚁侧真机急病：名单刷新/作品页切页签时查询撞上已关闭的句柄，
// 弹 DatabaseException(database_closed 10)。凡人同套路自查坐实
// 两处同病：
//  1) 单例 SqfliteActressDatabase 内部开库没带 singleInstance:
//     false——sqflite 默认单例按路径缓存实例，探库
//     (_looksLikeActressDb/_looksLikeVideoLibraryDb)对同一路径
//     open 拿到的是页面正在用的活连接，finally 里 close() 等于
//     关共享句柄；reloadIfChanged 换库时先经 _openDbAt 探库，
//     活连接在换库完成前就被探库关掉。
//  2) 页面查询与关库/换库并发时没有重开重试：在途查询拿到旧
//     句柄、提交时句柄已关，直接把 database_closed 抛到页面。
//
// 本机跑不了真 sqflite（无 ffi 工厂，与 actress_db_dual_test
// 同口径），复现分两档：
//  - 源码不变量：actress_database.dart 里每个 openDatabase 都
//    必须带 singleInstance: false（照 actress_nvku_loadfix_test
//    的开库姿势断言口径）；改前 3 处缺失，本测试改前必败。
//  - 等价时序模型：用记账假句柄模拟「查询在途时句柄被关」——
//    无防护时查询抛 database_closed（复现症状）；经
//    retryOnceOnClosedDb 防护后整段重跑、换新句柄成功。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_database.dart';

/// 记账假句柄：模拟 sqflite 句柄的关后语义——关掉后再查询
/// 抛与真机同字面的 DatabaseException(database_closed 10)。
class _FakeHandle {
  _FakeHandle(this.id);

  final int id;
  var isOpen = true;
  var queryCount = 0;

  Future<List<Map<String, Object?>>> rawQuery(String sql) async {
    // sqflite 查询是异步提交的：调用方拿到句柄后，真正执行前
    // 句柄可能已被并发关掉——先让出一拍再查开关状态，还原
    // 「拿句柄→提交时已关」的真实时序。
    await Future<void>.delayed(Duration.zero);
    if (!isOpen) {
      throw Exception('DatabaseException(database_closed 10)');
    }
    queryCount++;
    return [
      {'c': queryCount},
    ];
  }

  Future<void> close() async {
    isOpen = false;
  }
}

void main() {
  group('源码不变量：单例内部开库一律独立连接', () {
    late String source;

    setUpAll(() {
      source = File('lib/actress/actress_database.dart').readAsStringSync();
    });

    test('actress_database.dart 每个 openDatabase 都带 singleInstance: false', () {
      final opens = 'openDatabase('.allMatches(source).toList();
      expect(opens, isNotEmpty, reason: '单例内部应有开库点');
      for (final match in opens) {
        // 取开库调用的参数区（到第一个配平的右括号前足够长的一段）。
        final tail = source.substring(match.start, match.start + 260);
        expect(
          tail.contains('singleInstance: false'),
          isTrue,
          reason:
              'openDatabase @${match.start} 缺 singleInstance: false：'
              '默认单例会按路径返回共享活连接，探库/候选库 close '
              '会误关页面正在用的句柄（database_closed 同病）',
        );
      }
    });

    test('关后重试防护已接：isActressDbClosedError + retryOnceOnClosedDb', () {
      expect(source.contains('bool isActressDbClosedError('), isTrue);
      expect(source.contains('retryOnceOnClosedDb'), isTrue);
      // 页面直面读法（名单/作品/计数）必须经防护层。
      for (final name in ['listPersons', 'worksForPerson', 'countPersons']) {
        expect(source.contains('$name('), isTrue, reason: '$name 应存在');
        expect(
          source.contains('retryOnceOnClosedDb'),
          isTrue,
          reason: '读法应经关后重试防护',
        );
      }
    });
  });

  group('关后错误识别', () {
    test('database_closed 字面命中，其它错误不误判', () {
      expect(
        isActressDbClosedError(Exception('DatabaseException(database_closed 10)')),
        isTrue,
      );
      expect(
        isActressDbClosedError(Exception('Database Closed')),
        isTrue,
      );
      expect(
        isActressDbClosedError(Exception('no such table: works')),
        isFalse,
      );
      expect(isActressDbClosedError(StateError('其它错误')), isFalse);
    });
  });

  group('等价时序复现：名单刷新在途时句柄被关', () {
    test('无防护：在途查询撞关库直接抛 database_closed（复现症状）', () async {
      final handle = _FakeHandle(1);
      // 查询先拿句柄、后提交（模拟 listPersons 拿 _open() 结果后
      // 再发 rawQuery 的时序）：提交前句柄被探库/换库关掉。
      await handle.close();
      await expectLater(
        handle.rawQuery('SELECT COUNT(*) FROM persons'),
        throwsA(
          predicate<Object>(
            (e) => isActressDbClosedError(e),
            'database_closed',
          ),
        ),
      );
    });

    test('有防护：撞关后整段重跑、换新句柄成功（切页签/刷新不再报错）', () async {
      var current = _FakeHandle(1);
      var runs = 0;
      Future<List<Map<String, Object?>>> loadPage() {
        return retryOnceOnClosedDb(() async {
          runs++;
          final db = current; // 相当于 await _open()：关后自愈拿新句柄
          return db.rawQuery('SELECT * FROM persons LIMIT 60');
        });
      }

      final pending = loadPage();
      // 查询在途时后台把旧句柄关掉（导入收尾/换库），并备好新句柄。
      await current.close();
      current = _FakeHandle(2);
      final rows = await pending;
      expect(rows, isNotEmpty);
      expect(runs, 2, reason: '第一次撞关、重试一次成功');
      expect(current.queryCount, 1);
    });

    test('非关库错误不重试，原样抛', () async {
      var runs = 0;
      await expectLater(
        retryOnceOnClosedDb(() async {
          runs++;
          throw StateError('结构错误');
        }),
        throwsStateError,
      );
      expect(runs, 1);
    });

    test('重试后仍撞关：只重试一次，第二次原样抛', () async {
      var runs = 0;
      await expectLater(
        retryOnceOnClosedDb(() async {
          runs++;
          throw Exception('DatabaseException(database_closed 10)');
        }),
        throwsA(predicate<Object>((e) => isActressDbClosedError(e))),
      );
      expect(runs, 2);
    });
  });
}
