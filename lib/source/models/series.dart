class Series {
  final String name;
  final String seriesId;
  final String? description;
  final String? image;
  final int? bgmId;
  final double? score;

  Series(
    this.seriesId,
    this.name, {
    this.description,
    this.image,
    this.bgmId,
    this.score,
  });

  @override
  String toString() => 'Name: $name\nId: $seriesId\nDescription: $description';
}
