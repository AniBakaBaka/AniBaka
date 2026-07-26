class Episode {
  final String episodeId;
  final int episode;
  final String? episodeName;

  String get name => episodeName ?? '第${episode + 1}集';

  Episode(this.episodeId, this.episode, [this.episodeName]);
}
