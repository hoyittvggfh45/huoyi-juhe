// 后台导入批测试（2026-11-28）：导入服务与页面解绑、防重
// 复、未完成识别、前台通知节流。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/import_job_service.dart';

class RecordingBridge implements ImportForegroundBridge {
  final starts = <String>[];
  final updates = <String>[];
  final stops = <String>[];

  @override
  Future<void> start(String text) async => starts.add(text);

  @override
  Future<void> update(String text, double fraction) async =>
      updates.add(text);

  @override
  Future<void> stop({required bool success, required String text}) async =>
      stops.add('$success:$text');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('import_job_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ImportJobService makeService({ImportForegroundBridge? bridge}) {
    return ImportJobService(
      supportDirectoryProvider: () async => tempDir,
      foreground: bridge ?? RecordingBridge(),
    );
  }

  test('①服务与页面解绑：订阅者中途退订，任务仍跑完且 succeeded', () async {
    final service = makeService();
    final gate = Completer<void>();
    final seen = <ImportJobPhase>[];
    void listener() => seen.add(service.state.value.phase);
    service.state.addListener(listener);

    final done = service.start(
      sourceName: '大文件.sql',
      runner: (onProgress, isCancelled) async {
        onProgress(
          const ImportJobProgress(
            kind: 'actress',
            phaseLabel: '正在导入',
            statements: 10,
            fraction: 0.1,
          ),
        );
        await gate.future; // 模拟慢导入：页面在此期间销毁
        onProgress(
          const ImportJobProgress(
            kind: 'actress',
            phaseLabel: '正在导入',
            statements: 99,
            fraction: 0.9,
          ),
        );
        return const ImportJobOutcome(ok: true, message: '导入成功');
      },
    );
    // 模拟页面 dispose：退订后任务不受影响。
    service.state.removeListener(listener);
    expect(service.isRunning, isTrue);
    gate.complete();
    expect(await done, isTrue);
    expect(service.state.value.phase, ImportJobPhase.succeeded);
    expect(service.state.value.message, '导入成功');
    expect(seen, contains(ImportJobPhase.running));
    // 标记文件已清除。
    expect(
      File('${tempDir.path}/${ImportJobService.markerFileName}').existsSync(),
      isFalse,
    );
  });

  test('②running 时第二次发起被拒，状态机不动', () async {
    final service = makeService();
    final gate = Completer<void>();
    final first = service.start(
      sourceName: 'a.sql',
      runner: (onProgress, isCancelled) async {
        await gate.future;
        return const ImportJobOutcome(ok: true);
      },
    );
    final second = await service.start(
      sourceName: 'b.sql',
      runner: (onProgress, isCancelled) async =>
          const ImportJobOutcome(ok: true),
    );
    expect(second, isFalse);
    expect(service.state.value.sourceName, 'a.sql');
    gate.complete();
    expect(await first, isTrue);
    expect(service.state.value.phase, ImportJobPhase.succeeded);
  });

  test('③标记残留＋无任务：启动识别 interrupted、清 staging、正式库不动', () async {
    final formal = File('${tempDir.path}/actress_library.db')
      ..writeAsStringSync('FORMAL');
    final staging = File('${tempDir.path}/actress_library.db.importing')
      ..writeAsStringSync('HALF');
    File('${tempDir.path}/actress_library.db.importing-wal')
        .writeAsStringSync('WAL');
    File('${tempDir.path}/${ImportJobService.markerFileName}')
        .writeAsStringSync('{"sourceName":"大文件.sql"}');

    final service = ImportJobService(
      supportDirectoryProvider: () async => tempDir,
      foreground: RecordingBridge(),
      stagingPathsProvider: () async => [staging.path],
    );
    await service.ensureStartupChecked();

    expect(service.state.value.phase, ImportJobPhase.interrupted);
    expect(service.state.value.error, ImportJobService.interruptedHintZh);
    expect(staging.existsSync(), isFalse);
    expect(
      File('${tempDir.path}/actress_library.db.importing-wal').existsSync(),
      isFalse,
    );
    // 半成品绝不生效：正式库一字未动。
    expect(formal.readAsStringSync(), 'FORMAL');
    expect(
      File('${tempDir.path}/${ImportJobService.markerFileName}').existsSync(),
      isFalse,
    );
  });

  test('④前台通知节流：start/stop 各 1 次，进度更新受节流', () async {
    final calls = <String>[];
    var now = DateTime(2026, 11, 28, 18, 0, 0);
    final bridge = MethodChannelImportForegroundBridge(
      invoke: (method, args) async {
        calls.add(method);
        return null;
      },
      now: () => now,
    );

    await bridge.start('正在导入数据库：x.sql');
    await bridge.update('p1', 0.10); // 首次：发
    now = now.add(const Duration(milliseconds: 500));
    await bridge.update('p2', 0.11); // <2s 且 <5%：节流
    now = now.add(const Duration(seconds: 1));
    await bridge.update('p3', 0.17); // 进度 ≥5%：发
    now = now.add(const Duration(milliseconds: 300));
    await bridge.update('p4', 0.18); // 节流
    now = now.add(const Duration(seconds: 3));
    await bridge.update('p5', 0.19); // ≥2s：发
    await bridge.stop(success: true, text: '数据库导入完成');

    expect(calls.where((c) => c == 'start').length, 1);
    expect(calls.where((c) => c == 'update').length, 3);
    expect(calls.where((c) => c == 'stop').length, 1);
  });

  test('⑤通道抛错 fail-soft：桥不抛、导入照常成功', () async {
    final bridge = MethodChannelImportForegroundBridge(
      invoke: (method, args) async => throw StateError('no channel'),
    );
    await bridge.start('x');
    await bridge.update('x', 0.5);
    await bridge.stop(success: false, text: 'x');

    final service = makeService(bridge: bridge);
    final ok = await service.start(
      sourceName: 'x.sql',
      runner: (onProgress, isCancelled) async =>
          const ImportJobOutcome(ok: true),
    );
    expect(ok, isTrue);
    expect(service.state.value.phase, ImportJobPhase.succeeded);
  });
}
