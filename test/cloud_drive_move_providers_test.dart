// 网盘建夹/移动接口形态测试（2026-11-28 补移动批）。
//
// 验收第一档：五家 provider 的 createFolder / moveFile 用
// MockClient 断言请求形态（域名/路径/方法/关键字段）与回
// 包解析。全部是夹具回包，不连真网盘——真账号实移逐家
// 列在报告的「待真机验」清单里，这里不冒充。
//
// 引擎层另测：ensureRootFolder 已有同名夹不重建、没有
// 才建；archiveMoveToCategoryFolder 成功/失败口径；执行
// 器把卡片 id 归一成文件 id 再落引擎。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/cloud_drive/cloud_credential_store.dart';
import 'package:fqapp/cloud_drive/cloud_drive_engine.dart';
import 'package:fqapp/cloud_drive/cloud_drive_types.dart';
import 'package:fqapp/cloud_drive/cloud_provider_139.dart';
import 'package:fqapp/cloud_drive/cloud_providers.dart';
import 'package:fqapp/cloud_drive/pan_scrape_move_executor.dart';

http_testing.MockClient _recording(
  List<http.Request> sink,
  http.Response Function(http.Request request) respond,
) {
  return http_testing.MockClient((request) async {
    sink.add(request);
    return respond(request);
  });
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

CloudDriveFile _file(String id, {Map<String, String> extra = const {}}) =>
    CloudDriveFile(
      id: id,
      name: '片.mp4',
      isFolder: false,
      kind: CloudFileKind.video,
      extra: extra,
    );

void main() {
  group('115 建夹/移动', () {
    const creds = CloudCredentials(fields: {'cookie': 'UID=x'}, savedAtMs: 1);

    test('建夹：POST files/add 表单 pid+cname，回包 cid 解析', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'state': true, 'cid': '9001', 'cname': '电影'}),
      );
      final folder = await Pan115Provider().createFolder(
        client,
        creds,
        '0',
        '电影',
      );
      expect(folder.id, '9001');
      expect(folder.isFolder, isTrue);
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.host, 'webapi.115.com');
      expect(request.url.path, '/files/add');
      final form = Uri.splitQueryString(request.body);
      expect(form['pid'], '0');
      expect(form['cname'], '电影');
      expect(request.headers['Cookie'], contains('UID=x'));
    });

    test('移动：POST files/move 表单 pid+fid', () async {
      final requests = <http.Request>[];
      final client = _recording(requests, (_) => _json({'state': true}));
      await Pan115Provider().moveFile(client, creds, _file('f7'), '9001');
      final request = requests.single;
      expect(request.url.path, '/files/move');
      final form = Uri.splitQueryString(request.body);
      expect(form['pid'], '9001');
      expect(form['fid'], 'f7');
    });

    test('建夹失败：state=false 把站方错误带出', () async {
      final client = _recording(
        <http.Request>[],
        (_) => _json({'state': false, 'error': '文件夹已存在'}),
      );
      await expectLater(
        Pan115Provider().createFolder(client, creds, '0', '电影'),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('夸克 建夹/移动', () {
    const creds = CloudCredentials(fields: {'cookie': 'k=v'}, savedAtMs: 1);

    test('建夹：POST /1/clouddrive/file JSON，回包 data.fid 解析', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({
          'status': 200,
          'code': 0,
          'data': {'fid': 'qf1'},
        }),
      );
      final folder = await QuarkProvider().createFolder(
        client,
        creds,
        '0',
        '电影',
      );
      expect(folder.id, 'qf1');
      final request = requests.single;
      expect(request.url.host, 'drive-pc.quark.cn');
      expect(request.url.path, '/1/clouddrive/file');
      expect(request.url.queryParameters['pr'], 'ucpro');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['pdir_fid'], '0');
      expect(body['file_name'], '电影');
      expect(body['dir_init_lock'], isFalse);
    });

    test('移动：POST file/move，action_type=1 + filelist + to_pdir_fid', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'status': 200, 'code': 0, 'data': <String, dynamic>{}}),
      );
      await QuarkProvider().moveFile(client, creds, _file('f9'), 'qf1');
      final request = requests.single;
      expect(request.url.path, '/1/clouddrive/file/move');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['action_type'], 1);
      expect(body['filelist'], ['f9']);
      expect(body['to_pdir_fid'], 'qf1');
    });

    test('移动失败：status/code 非成功把 message 带出', () async {
      final client = _recording(
        <http.Request>[],
        (_) => _json({'status': 500, 'code': 1, 'message': '目标文件夹不存在'}),
      );
      await expectLater(
        QuarkProvider().moveFile(client, creds, _file('f9'), 'qf1'),
        throwsA(
          isA<CloudDriveException>().having(
            (e) => e.message,
            'message',
            contains('目标文件夹不存在'),
          ),
        ),
      );
    });
  });

  group('百度 建夹/移动', () {
    const creds = CloudCredentials(fields: {'cookie': 'BDUSS=x'}, savedAtMs: 1);

    test('建夹：method=create 表单 path/isdir，回包 fs_id+path', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'errno': 0, 'fs_id': 12345, 'path': '/电影'}),
      );
      final folder = await BaiduProvider().createFolder(
        client,
        creds,
        '/',
        '电影',
      );
      expect(folder.id, '12345');
      expect(folder.extra['path'], '/电影');
      final request = requests.single;
      expect(request.url.queryParameters['method'], 'create');
      final form = Uri.splitQueryString(request.body);
      expect(form['path'], '/电影');
      expect(form['isdir'], '1');
      expect(form['rtype'], '0');
    });

    test('移动：method=filemanager&opera=move，filelist 按路径寻址', () async {
      final requests = <http.Request>[];
      final client = _recording(requests, (_) => _json({'errno': 0}));
      await BaiduProvider().moveFile(
        client,
        creds,
        _file('888', extra: const {'path': '/旧夹/片.mp4'}),
        '12345',
        targetFolderPath: '/电影',
      );
      final request = requests.single;
      expect(request.url.queryParameters['method'], 'filemanager');
      expect(request.url.queryParameters['opera'], 'move');
      final form = Uri.splitQueryString(request.body);
      final filelist = jsonDecode(form['filelist']!) as List<dynamic>;
      final op = filelist.single as Map<String, dynamic>;
      expect(op['path'], '/旧夹/片.mp4');
      expect(op['dest'], '/电影');
      expect(op['newname'], '片.mp4');
      expect(op['ondup'], 'fail');
    });

    test('移动缺源路径：不发请求、如实报错', () async {
      final requests = <http.Request>[];
      final client = _recording(requests, (_) => _json({'errno': 0}));
      await expectLater(
        BaiduProvider().moveFile(
          client,
          creds,
          _file('888'),
          '12345',
          targetFolderPath: '/电影',
        ),
        throwsA(isA<CloudDriveException>()),
      );
      expect(requests, isEmpty);
    });
  });

  group('阿里 建夹/移动', () {
    const creds = CloudCredentials(
      fields: {
        'access_token': 'tok1',
        'refresh_token': 'rt1',
        'drive_id': 'drv1',
      },
      savedAtMs: 1,
    );

    test('建夹：openFile/create 带 Bearer，回包 file_id 解析', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'file_id': 'af1', 'type': 'folder'}, 201),
      );
      final folder = await AliyunProvider().createFolder(
        client,
        creds,
        'root',
        '电影',
      );
      expect(folder.id, 'af1');
      final request = requests.single;
      expect(request.url.path, '/adrive/v1.0/openFile/create');
      expect(request.headers['Authorization'], 'Bearer tok1');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['drive_id'], 'drv1');
      expect(body['parent_file_id'], 'root');
      expect(body['name'], '电影');
      expect(body['type'], 'folder');
      expect(body['check_name_mode'], 'refuse');
    });

    test('移动：openFile/move 带 drive_id/file_id/to_parent_file_id', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'file_id': 'f3'}),
      );
      await AliyunProvider().moveFile(client, creds, _file('f3'), 'af1');
      final request = requests.single;
      expect(request.url.path, '/adrive/v1.0/openFile/move');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['drive_id'], 'drv1');
      expect(body['file_id'], 'f3');
      expect(body['to_parent_file_id'], 'af1');
    });
  });

  group('移动云盘 建夹/移动', () {
    const creds = CloudCredentials(
      fields: {'authorization': 'Basic abc'},
      savedAtMs: 1,
    );

    test('建夹：hcy/file/create type=folder，回包 data.fileId 解析', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({
          'success': true,
          'code': '000000',
          'data': {'fileId': 'n139f', 'name': '电影', 'type': 'folder'},
        }),
      );
      final folder = await Yun139Provider().createFolder(
        client,
        creds,
        '/',
        '电影',
      );
      expect(folder.id, 'n139f');
      expect(folder.isFolder, isTrue);
      final request = requests.single;
      expect(request.url.host, 'personal-kd-njs.yun.139.com');
      expect(request.url.path, '/hcy/file/create');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['parentFileId'], '/');
      expect(body['name'], '电影');
      expect(body['type'], 'folder');
    });

    test('移动：hcy/file/batchMove fileIds+toParentFileId', () async {
      final requests = <http.Request>[];
      final client = _recording(
        requests,
        (_) => _json({'success': true, 'code': '000000'}),
      );
      await Yun139Provider().moveFile(client, creds, _file('m5'), 'n139f');
      final request = requests.single;
      expect(request.url.path, '/hcy/file/batchMove');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['fileIds'], ['m5']);
      expect(body['toParentFileId'], 'n139f');
    });

    test('移动失败：success=false 抛错', () async {
      final client = _recording(
        <http.Request>[],
        (_) => _json({'success': false, 'message': '文件不存在'}),
      );
      await expectLater(
        Yun139Provider().moveFile(client, creds, _file('m5'), 'n139f'),
        throwsA(isA<CloudDriveException>()),
      );
    });
  });

  group('引擎归档移动（桩 provider）', () {
    late _StubProvider stub;
    late CloudDriveEngine engine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = CloudCredentialStore(prefs);
      await store.save(
        'stub',
        const CloudCredentials(fields: {'cookie': 'a=b'}, savedAtMs: 1),
      );
      stub = _StubProvider();
      engine = CloudDriveEngine(
        credentialStore: store,
        httpClient: http_testing.MockClient((_) async => _json({})),
        showSuspectedAds: () => false,
        providers: {'stub': stub},
      );
    });

    test('根下已有同名夹：不重建、直接用它移动', () async {
      stub.rootFiles = const [
        CloudDriveFile(
          id: 'dir-existing',
          name: '电影',
          isFolder: true,
          kind: CloudFileKind.folder,
        ),
      ];
      final result = await engine.archiveMoveToCategoryFolder(
        providerId: 'stub',
        fileId: 'file1',
        folderName: '电影',
      );
      expect(result.moved, isTrue);
      expect(stub.createCalls, 0);
      expect(stub.moveCalls.single.targetId, 'dir-existing');
      expect(stub.moveCalls.single.fileId, 'file1');
    });

    test('根下没有同名夹：先建夹再移入新夹', () async {
      stub.rootFiles = const [];
      final result = await engine.archiveMoveToCategoryFolder(
        providerId: 'stub',
        fileId: 'file2',
        folderName: '电视剧',
      );
      expect(result.moved, isTrue);
      expect(stub.createCalls, 1);
      expect(stub.moveCalls.single.targetId, 'dir-created');
    });

    test('移动失败：回 (false, 原因)，不抛错', () async {
      stub.moveError = '网盘说不行';
      final result = await engine.archiveMoveToCategoryFolder(
        providerId: 'stub',
        fileId: 'file3',
        folderName: '电影',
      );
      expect(result.moved, isFalse);
      expect(result.reason, contains('网盘说不行'));
    });

    test('执行器：卡片 id 归一成文件 id 后落引擎', () async {
      final executor = EnginePanDriveMoveExecutor(
        engineProvider: () async => engine,
      );
      final ok = await executor.moveToCategoryFolder(
        providerId: 'stub',
        itemId: 'stub:file9',
        folderName: '电影',
      );
      expect(ok, isTrue);
      expect(stub.moveCalls.single.fileId, 'file9');
      expect(executor.lastMoveError, isNull);
    });
  });
}

/// 桩 provider：只实现引擎归档路径用到的方法。
class _StubProvider extends CloudDriveProvider {
  @override
  String get id => 'stub';
  @override
  String get displayName => '桩网盘';
  @override
  String get appName => 'stub';
  @override
  String get rootFolderId => '0';

  List<CloudDriveFile> rootFiles = const [];
  int createCalls = 0;
  String? moveError;
  final moveCalls = <({String fileId, String targetId})>[];

  @override
  void Function(String, CloudCredentials)? onCredentialsRefreshed;
  @override
  void Function(String, String)? onSessionExpired;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) =>
      throw UnimplementedError();

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) => throw UnimplementedError();

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async => CloudFolderPage(files: rootFiles, hasMore: false);

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) => throw UnsupportedError('桩无搜索');

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) => throw UnimplementedError();

  @override
  Future<CloudDriveFile> createFolder(
    http.Client client,
    CloudCredentials credentials,
    String parentId,
    String name,
  ) async {
    createCalls++;
    return CloudDriveFile(
      id: 'dir-created',
      name: name,
      isFolder: true,
      kind: CloudFileKind.folder,
    );
  }

  @override
  Future<void> moveFile(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
    String targetFolderId, {
    String? targetFolderPath,
  }) async {
    final error = moveError;
    if (error != null) throw CloudDriveException(error);
    moveCalls.add((fileId: file.id, targetId: targetFolderId));
  }
}
