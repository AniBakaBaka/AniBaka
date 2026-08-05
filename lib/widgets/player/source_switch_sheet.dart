import 'package:flutter/material.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';
import 'package:baka/widgets/anime_detail/video_source_search_sheet.dart';

export 'package:baka/widgets/anime_detail/video_source_search_sheet.dart'
    show SourceSwitchSelection;

class SourceSwitchSheet {
  SourceSwitchSheet._();

  static Future<SourceSwitchSelection?> show(
    BuildContext context, {
    required String title,
    required String cover,
    required Map<String, dynamic> seedData,
    required int currentEpisodeIndex,
    required int currentLineIndex,
    String? currentSource,
    String? currentSourceName,
    VideoSourceSearchController? searchController,
  }) {
    return VideoSourceSearchSheet.show(
      context,
      title: title,
      cover: cover,
      seedData: seedData,
      currentEpisodeIndex: currentEpisodeIndex,
      currentLineIndex: currentLineIndex,
      currentSource: currentSource,
      currentSourceName: currentSourceName,
      searchController: searchController,
    );
  }
}
