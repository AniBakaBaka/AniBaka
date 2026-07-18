import 'package:baka/source/models/episode.dart';

class Source {
  final List<Episode> episodes;
  final String? sourceName;

  Source(this.episodes, [this.sourceName]);

  Source.fromDynamicJson(dynamic json)
    : episodes =
          (json['episodes'] as List?)
              ?.map((e) => Episode.fromDynamicJson(e))
              .toList() ??
          const [],
      sourceName = json['sourceName']?.toString();
}
