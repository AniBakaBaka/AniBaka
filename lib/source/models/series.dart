class Series {
  final String name;
  final String seriesId;
  String? description;
  String? image;
  int? bgmId;
  double? score;

  Series(
    this.seriesId,
    this.name, {
    this.description,
    this.image,
    this.bgmId,
    this.score,
  });
}
