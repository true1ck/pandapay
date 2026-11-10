/// Plain-text formatting shared by the voice review sheet, answers and spoken
/// replies, so the same figure always reads the same way.
class VoiceFormat {
  const VoiceFormat._();

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// ₹1,250 or ₹2,50,000 or ₹99.50 (Indian digit grouping).
  static String rupees(double value) {
    final negative = value < 0;
    final v = value.abs();
    final whole = v == v.roundToDouble();
    final text = whole ? v.toInt().toString() : v.toStringAsFixed(2);
    final parts = text.split('.');
    var integer = parts[0];
    if (integer.length > 3) {
      final last3 = integer.substring(integer.length - 3);
      var rest = integer.substring(0, integer.length - 3);
      final groups = <String>[];
      while (rest.length > 2) {
        groups.insert(0, rest.substring(rest.length - 2));
        rest = rest.substring(0, rest.length - 2);
      }
      if (rest.isNotEmpty) groups.insert(0, rest);
      integer = '${groups.join(',')},$last3';
    }
    final fraction = parts.length > 1 ? '.${parts[1]}' : '';
    return '${negative ? '-' : ''}₹$integer$fraction';
  }

  /// "Today", "Yesterday", "Fri 6 Nov" or "3 Nov 2025".
  static String day(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = (today.difference(day).inHours / 24).round();
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    final base = '${d.day} ${_months[d.month - 1]}';
    if (d.year != today.year) return '$base ${d.year}';
    return '${_weekdays[d.weekday - 1]} $base';
  }

  /// "1 Nov to 10 Nov" or "Today".
  static String range(DateTime from, DateTime to, DateTime now) {
    if (from == to) return day(from, now);
    String short(DateTime d) {
      final base = '${d.day} ${_months[d.month - 1]}';
      return d.year == now.year ? base : '$base ${d.year}';
    }

    return '${short(from)} to ${short(to)}';
  }
}
