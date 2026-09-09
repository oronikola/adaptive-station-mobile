import 'models.dart';

export 'models.dart' show Student, AttendanceTap, NotificationPreferences;

abstract final class DemoAttendance {
  static const alex = Student(
    'alex',
    'Alex Santos',
    'AS',
    'Grade 7 · Section Emerald',
    'Northfield School',
  );
  static const mia = Student(
    'mia',
    'Mia Santos',
    'MS',
    'Grade 4 · Section Maple',
    'Northfield School',
  );
  static const children = [alex, mia];
  static final taps = [
    AttendanceTap(
      'tap-1',
      alex,
      true,
      '7:35 AM',
      'Sep 7, 2026',
      'Main Gate',
      DateTime(2026, 9, 7, 7, 35),
    ),
    AttendanceTap(
      'tap-2',
      mia,
      true,
      '7:28 AM',
      'Sep 7, 2026',
      'Elementary Gate',
      DateTime(2026, 9, 7, 7, 28),
    ),
    AttendanceTap(
      'tap-3',
      alex,
      false,
      '4:12 PM',
      'Sep 4, 2026',
      'Main Gate',
      DateTime(2026, 9, 4, 16, 12),
    ),
    AttendanceTap(
      'tap-4',
      mia,
      false,
      '3:05 PM',
      'Sep 4, 2026',
      'Elementary Gate',
      DateTime(2026, 9, 4, 15, 5),
    ),
  ];
}
