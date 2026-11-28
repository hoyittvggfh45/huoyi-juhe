import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/hgtv_content.dart';
import 'package:fqapp/services/hongguo_identity.dart';

HongguoIdentityService _service({
  required MemoryHongguoIdentityStore store,
  required String Function() ip,
  required DateTime Function() clock,
}) {
  return HongguoIdentityService(
    store: store,
    ipProbe: () async => ip(),
    clock: clock,
  );
}

void main() {
  group('确定性派生', () {
    const deriver = HongguoIdentityDeriver();

    test('同机型同 IP 同一天同轮次：复现同一套', () {
      final a = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-29', generation: 0);
      final b = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-29', generation: 0);
      expect(a.deviceId, b.deviceId);
      expect(a.installId, b.installId);
    });

    test('id 形态与现行口径一致：19 位数字、cdid 恒等于 device_id', () {
      final id = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-29', generation: 0);
      expect(RegExp(r'^\d{19}$').hasMatch(id.deviceId), isTrue);
      expect(RegExp(r'^\d{19}$').hasMatch(id.installId), isTrue);
      expect(id.cdid, id.deviceId);
      expect(id.deviceId, isNot(id.installId));
    });

    test('跨天不同、换 IP 不同、轮次 +1 不同', () {
      final base = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-29', generation: 0);
      final nextDay = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-30', generation: 0);
      final otherIp = deriver.derive(ip: '5.6.7.8', dateStamp: '2026-11-29', generation: 0);
      final nextGen = deriver.derive(ip: '1.2.3.4', dateStamp: '2026-11-29', generation: 1);
      expect(nextDay.deviceId, isNot(base.deviceId));
      expect(otherIp.deviceId, isNot(base.deviceId));
      expect(nextGen.deviceId, isNot(base.deviceId));
    });
  });

  group('轮换服务触发口径', () {
    test('首次生成并落盘；同日同 IP 再校验复用同一套、不重写', () async {
      final store = MemoryHongguoIdentityStore();
      var now = DateTime(2026, 11, 29, 10);
      final service = _service(store: store, ip: () => '1.2.3.4', clock: () => now);
      final first = await service.ensureCurrent();
      expect(store.writeCount, 1);
      now = DateTime(2026, 11, 29, 22);
      final again = await service.ensureCurrent();
      expect(again.deviceId, first.deviceId);
      expect(again.installId, first.installId);
      expect(store.writeCount, 1);
    });

    test('跨天换一套（轮次归 0）', () async {
      final store = MemoryHongguoIdentityStore();
      var now = DateTime(2026, 11, 29, 23, 59);
      final service = _service(store: store, ip: () => '1.2.3.4', clock: () => now);
      final first = await service.ensureCurrent();
      now = DateTime(2026, 11, 30, 0, 1);
      final next = await service.ensureCurrent();
      expect(next.deviceId, isNot(first.deviceId));
      expect(next.dateStamp, '2026-11-30');
      expect(next.generation, 0);
    });

    test('换 IP 换一套；IP 探不到（unknown）不算换网、不乱换', () async {
      final store = MemoryHongguoIdentityStore();
      var ip = '1.2.3.4';
      final service = _service(
        store: store,
        ip: () => ip,
        clock: () => DateTime(2026, 11, 29, 10),
      );
      final first = await service.ensureCurrent();
      ip = HongguoIdentityService.unknownIp;
      final probeDown = await service.ensureCurrent();
      expect(probeDown.deviceId, first.deviceId);
      ip = '5.6.7.8';
      final moved = await service.ensureCurrent();
      expect(moved.deviceId, isNot(first.deviceId));
      expect(moved.ipStamp, '5.6.7.8');
    });

    test('被拒标记后：同日同 IP 也换新、轮次 +1、标记清掉', () async {
      final store = MemoryHongguoIdentityStore();
      final service = _service(
        store: store,
        ip: () => '1.2.3.4',
        clock: () => DateTime(2026, 11, 29, 10),
      );
      final first = await service.ensureCurrent();
      await service.markRejected();
      expect(store.rejected, isTrue);
      final rotated = await service.ensureCurrent();
      expect(rotated.deviceId, isNot(first.deviceId));
      expect(rotated.generation, first.generation + 1);
      expect(store.rejected, isFalse);
      // 换新后同日同 IP 再校验：复用新的一套，不连环换。
      final settled = await service.ensureCurrent();
      expect(settled.deviceId, rotated.deviceId);
    });

    test('落盘损坏时不抛：重新派生一套可用的', () async {
      final store = MemoryHongguoIdentityStore()
        ..stored = const HongguoAnonIdentity(
          deviceId: 'x',
          installId: 'y',
          dateStamp: '',
          ipStamp: '',
          generation: 0,
        );
      final service = _service(
        store: store,
        ip: () => '1.2.3.4',
        clock: () => DateTime(2026, 11, 29, 10),
      );
      final fresh = await service.ensureCurrent();
      expect(fresh.isWellFormed, isTrue);
    });
  });

  group('客户端定格与一致性', () {
    test('注入身份进 query：device_id/iid/cdid 同源一致', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({'code': 0, 'data': {'video_data': [], 'has_more': false}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      const identity = HongguoAnonIdentity(
        deviceId: '1111111111111111111',
        installId: '2222222222222222222',
        dateStamp: '2026-11-29',
        ipStamp: '1.2.3.4',
        generation: 0,
      );
      final client = HgtvContentClient(mock, null, identity);
      await client.catalog('home', 1);
      expect(requests, isNotEmpty);
      final query = requests.first.queryParameters;
      expect(query['device_id'], identity.deviceId);
      expect(query['iid'], identity.installId);
      expect(query['cdid'], identity.deviceId);
    });

    test('版本档案全链对齐：query 与 UA 同为 7.4.3.32 / 74332', () async {
      final requests = <Uri>[];
      final seenHeaders = <Map<String, String>>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        seenHeaders.add(request.headers);
        return http.Response(
          jsonEncode({'code': 0, 'data': {'video_data': [], 'has_more': false}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final store = MemoryHongguoIdentityStore();
      final service = _service(
        store: store,
        ip: () => '1.2.3.4',
        clock: () => DateTime(2026, 11, 29, 10),
      );
      await service.ensureCurrent();
      final client = HgtvContentClient(mock, null, null, service);
      await client.catalog('home', 1);
      final query = requests.first.queryParameters;
      expect(query['version_name'], '7.4.3.32');
      expect(query['version_code'], '74332');
      expect(query['manifest_version_code'], '74332');
      expect(query['update_version_code'], '74332');
      expect(query['pv_player'], '74332');
      expect(query['device_type'], '25053RT47C');
      expect(query['device_brand'], 'Redmi');
      final ua = seenHeaders.first['User-Agent'] ?? '';
      expect(ua, contains('74332'));
      expect(ua, contains('25053RT47C'));
    });

    test('播放途中不换：客户端构造后服务轮换，已构造客户端仍用旧身份', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode({'code': 0, 'data': {'video_data': [], 'has_more': false}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final store = MemoryHongguoIdentityStore();
      var ip = '1.2.3.4';
      final service = _service(
        store: store,
        ip: () => ip,
        clock: () => DateTime(2026, 11, 29, 10),
      );
      final first = await service.ensureCurrent();
      final client = HgtvContentClient(mock, null, null, service);
      expect(client.identity.deviceId, first.deviceId);
      // 模拟换网后服务轮换：新客户端拿到新身份，老客户端纹丝不动。
      ip = '5.6.7.8';
      final rotated = await service.ensureCurrent();
      expect(rotated.deviceId, isNot(first.deviceId));
      await client.catalog('home', 1);
      expect(requests.last.queryParameters['device_id'], first.deviceId);
      final nextClient = HgtvContentClient(mock, null, null, service);
      expect(nextClient.identity.deviceId, rotated.deviceId);
    });

    test('被拒（回空）置标记：本轮失败收尾，下一次构造换新身份', () async {
      final mock = MockClient((request) async {
        return http.Response('', 200);
      });
      final store = MemoryHongguoIdentityStore();
      final service = _service(
        store: store,
        ip: () => '1.2.3.4',
        clock: () => DateTime(2026, 11, 29, 10),
      );
      final first = await service.ensureCurrent();
      final client = HgtvContentClient(mock, null, null, service);
      await expectLater(client.catalog('home', 1), throwsStateError);
      expect(store.rejected, isTrue);
      final rotated = await service.ensureCurrent();
      expect(rotated.deviceId, isNot(first.deviceId));
      expect(rotated.generation, first.generation + 1);
    });

    test('被拒（明确拒绝码）同样置标记', () async {
      final mock = MockClient((request) async {
        return http.Response(jsonEncode({'code': 100103}), 200);
      });
      final store = MemoryHongguoIdentityStore();
      final service = _service(
        store: store,
        ip: () => '1.2.3.4',
        clock: () => DateTime(2026, 11, 29, 10),
      );
      await service.ensureCurrent();
      final client = HgtvContentClient(mock, null, null, service);
      await expectLater(client.catalog('home', 1), throwsStateError);
      expect(store.rejected, isTrue);
    });
  });
}
