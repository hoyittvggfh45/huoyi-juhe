/// 真实移动执行器（2026-11-28 补移动批）：把
/// [PanDriveMoveExecutor] 落到 [CloudDriveEngine]——引擎
/// 在网盘根下确保分类文件夹存在（已有不重建），再调各家
/// provider 的 moveFile 把条目移入。五家 provider 的建夹/
/// 移动接口都在 cloud_providers.dart /
/// cloud_provider_139.dart 里按各自鉴权体系补齐。
///
/// [itemId] 约定：引擎卡片 id（`<网盘>:<文件id>`）或裸
/// 文件 id 都认，内部按 CloudDriveEngine.fileIdOf 归一。
/// 失败不抛错：回 false 并把具体原因留在 [lastMoveError]，
/// 归档器据此逐条记账（哪条为什么没移成，一查便知）。
library;

import 'cloud_drive_engine.dart';
import 'pan_scrape_archive.dart';

class EnginePanDriveMoveExecutor implements PanDriveMoveExecutor {
  EnginePanDriveMoveExecutor({
    required Future<CloudDriveEngine> Function() engineProvider,
  }) : _engineProvider = engineProvider;

  final Future<CloudDriveEngine> Function() _engineProvider;

  /// 最近一次移动失败的原因（成功时为 null）。
  String? lastMoveError;

  @override
  Future<bool> moveToCategoryFolder({
    required String providerId,
    required String itemId,
    required String folderName,
  }) async {
    lastMoveError = null;
    try {
      final engine = await _engineProvider();
      final result = await engine.archiveMoveToCategoryFolder(
        providerId: providerId,
        fileId: CloudDriveEngine.fileIdOf(itemId),
        folderName: folderName,
      );
      if (!result.moved) lastMoveError = result.reason;
      return result.moved;
    } catch (e) {
      lastMoveError = '移动失败：$e';
      return false;
    }
  }
}
