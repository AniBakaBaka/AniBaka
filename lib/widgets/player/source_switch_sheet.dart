import 'package:flutter/material.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';

class SourceSwitchSheet {
  SourceSwitchSheet._();

  /// 展示字段统一从 [seedData] 解析，避免调用方重复拆 title/cover。
  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required Map<String, dynamic> seedData,
    required int currentEpisodeIndex,
    required int currentLineIndex,
    String? currentSource,
    VideoSourceSearchController? searchController,
    String? heroTag,
  }) {
    return VideoSourceSearchSheet.show(
      context,
      seedData: seedData,
      currentEpisodeIndex: currentEpisodeIndex,
      currentLineIndex: currentLineIndex,
      currentSource: currentSource,
      searchController: searchController,
      heroTag: heroTag,
    );
  }
}
