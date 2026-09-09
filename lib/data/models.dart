class Student {
  const Student(this.id, this.name, this.initials, this.className, this.school);
  final String id;
  final String name;
  final String initials;
  final String className;
  final String school;

  factory Student.fromJson(Map<String, dynamic> json) {
    final name = (json['display_name'] as String?)?.trim();
    final displayName = (name == null || name.isEmpty) ? 'Student' : name;
    final parts = displayName.split(RegExp(r'\s+'));
    final initials = parts.length >= 2
        ? '${parts.first[0]}${parts.last[0]}'.toUpperCase()
        : parts.first.substring(0, 1).toUpperCase();

    final grade = (json['grade_level'] as String?)?.trim();
    final section = (json['section'] as String?)?.trim();
    final className = [
      if (grade != null && grade.isNotEmpty) grade,
      if (section != null && section.isNotEmpty) section,
    ].join(' · ');

    return Student(json['id'] as String, displayName, initials, className, '');
  }
}

class AttendanceTap {
  const AttendanceTap(
    this.id,
    this.student,
    this.isIn,
    this.time,
    this.date,
    this.station,
    this.occurredAt,
  );
  final String id;
  final Student student;
  final bool isIn;
  final String time;
  final String date;
  final String station;
  final DateTime occurredAt;

  /// occurred_at arrives as a UTC ISO-8601 timestamp — converted to the
  /// device's local time here, which for this app's Philippines-based
  /// families matches the school's own timezone closely enough for display.
  /// Shared by the REST attendance response and the live "tap.recorded"
  /// broadcast payload — both carry the same id/event_type/occurred_at/
  /// station shape, so one factory covers both.
  factory AttendanceTap.fromJson(Map<String, dynamic> json, Student student) {
    final occurredAt = DateTime.parse(json['occurred_at'] as String).toLocal();

    return AttendanceTap(
      json['id'] as String,
      student,
      json['event_type'] == 'IN',
      formatTapTime(occurredAt),
      formatTapDate(occurredAt),
      (json['station'] as String?) ?? '',
      occurredAt,
    );
  }
}

class NotificationPreferences {
  const NotificationPreferences({
    required this.notifyIn,
    required this.notifyOut,
  });
  final bool notifyIn;
  final bool notifyOut;

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) =>
      NotificationPreferences(
        notifyIn: json['notify_in'] as bool? ?? true,
        notifyOut: json['notify_out'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
    'notify_in': notifyIn,
    'notify_out': notifyOut,
  };

  NotificationPreferences copyWith({bool? notifyIn, bool? notifyOut}) =>
      NotificationPreferences(
        notifyIn: notifyIn ?? this.notifyIn,
        notifyOut: notifyOut ?? this.notifyOut,
      );
}

const _months = [
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

String formatTapTime(DateTime local) {
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $period';
}

String formatTapDate(DateTime local) =>
    '${_months[local.month - 1]} ${local.day}, ${local.year}';
