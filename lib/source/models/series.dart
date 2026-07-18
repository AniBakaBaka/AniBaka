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

  Series.fromDynamicJson(dynamic json)
    : seriesId = json['seriesId']?.toString() ?? '',
      name = json['name']?.toString() ?? '',
      description = json['description']?.toString(),
      image = json['image']?.toString(),
      bgmId = (json['bgmId'] as num?)?.toInt(),
      score = (json['score'] as num?)?.toDouble();

  @override
  String toString() => 'Name: $name\nId: $seriesId\nDescription: $description';
}
