import 'dart:core';
void main() {
  DateTime now = DateTime.now();
  int daysToSubtract = (now.weekday + 1) % 7;
  DateTime currentSaturday = DateTime(now.year, now.month, now.day).subtract(Duration(days: daysToSubtract));
  
  List<DateTime> getBounds(int weekOffset) {
    DateTime startOfWeek = currentSaturday.add(Duration(days: weekOffset * 7));
    DateTime endOfWeek = startOfWeek.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    return [startOfWeek, endOfWeek];
  }
  
  print("Now: $now");
  print("-1 Week: ${getBounds(-1)}");
  print(" 0 Week: ${getBounds(0)}");
  print(" 1 Week: ${getBounds(1)}");
}
