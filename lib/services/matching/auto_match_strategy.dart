abstract final class AutoMatchStrategy {
  static const double immediateProbeConfidence = 0.70;
  static const double priorityProbeConfidence = 0.82;
  static const double finalProbeConfidence = 0.60;

  static const int raceConcurrency = 5;
  static const int maxLinesPerCandidate = 2;
  static const int keywordsPerSourceAuto = 1;
  static const int keywordsPerSourceManual = 2;

  static const Duration candidateBudget = Duration(milliseconds: 5500);
  static const Duration wallClock = Duration(seconds: 12);
}
