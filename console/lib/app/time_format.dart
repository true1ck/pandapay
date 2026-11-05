/// Short, human durations for operational screens ("6 min", "3 days ago").
String formatAge(int seconds) {
  if (seconds < 90) return '${seconds}s';
  if (seconds < 5400) return '${(seconds / 60).round()} min';
  if (seconds < 172800) return '${(seconds / 3600).round()} h';
  return '${(seconds / 86400).round()} days';
}

String formatAgo(DateTime at, {DateTime? now}) {
  final seconds = (now ?? DateTime.now()).difference(at).inSeconds;
  if (seconds < 60) return 'just now';
  return '${formatAge(seconds)} ago';
}
