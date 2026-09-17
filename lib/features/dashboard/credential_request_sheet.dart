import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../design/components.dart';
import '../../design/station_theme.dart';

/// A two-step request flow. It intentionally receives only a child selection
/// and safe delivery metadata; credential values are never part of this UI.
class CredentialRequestSheet extends StatefulWidget {
  const CredentialRequestSheet({
    super.key,
    required this.children,
    required this.onRequest,
  });

  final List<Student> children;
  final Future<CredentialDelivery> Function(Student student) onRequest;

  @override
  State<CredentialRequestSheet> createState() => _CredentialRequestSheetState();
}

class _CredentialRequestSheetState extends State<CredentialRequestSheet> {
  late Student _student = widget.children.first;
  bool _reviewing = false;
  bool _sending = false;
  String? _error;
  CredentialDelivery? _delivery;

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final delivery = await widget.onRequest(_student);
      if (!mounted) return;
      setState(() {
        _delivery = delivery;
        _sending = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not send the credentials. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = StationPalette.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: _delivery != null
            ? _success(context, palette)
            : _reviewing
            ? _review(context, palette)
            : _select(context, palette),
      ),
    );
  }

  Widget _select(BuildContext context, StationPalette palette) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: palette.border,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text('Get student credentials', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text(
        'Choose a child. Their existing login credentials will be sent by SMS to the verified primary guardian number.',
        style: TextStyle(color: palette.muted),
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<Student>(
        value: _student,
        decoration: const InputDecoration(labelText: 'Student'),
        items: widget.children
            .map((student) => DropdownMenuItem(value: student, child: Text(student.name)))
            .toList(),
        onChanged: (student) {
          if (student != null) setState(() => _student = student);
        },
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => setState(() => _reviewing = true),
          child: const Text('Continue'),
        ),
      ),
    ],
  );

  Widget _review(BuildContext context, StationPalette palette) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Confirm request', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      StationCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_student.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (_student.className.isNotEmpty) Text(_student.className),
            const SizedBox(height: 12),
            Text(
              'Essential will send this student\'s existing username and password to the verified primary guardian number by SMS.',
              style: TextStyle(color: palette.muted),
            ),
          ],
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 20),
      Row(
        children: [
          TextButton(
            onPressed: _sending ? null : () => setState(() => _reviewing = false),
            child: const Text('Back'),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sms_outlined),
            label: Text(_sending ? 'Sending…' : 'Send credentials'),
          ),
        ],
      ),
    ],
  );

  Widget _success(BuildContext context, StationPalette palette) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.check_circle_outline, color: Theme.of(context).colorScheme.primary, size: 40),
      const SizedBox(height: 16),
      Text('Credentials queued', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text(
        _delivery!.maskedPhone.isEmpty
            ? 'The credentials for ${_student.name} are queued for the verified primary guardian number.'
            : 'The credentials for ${_student.name} are queued for delivery to ${_delivery!.maskedPhone}.',
        style: TextStyle(color: palette.muted),
      ),
      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ),
    ],
  );
}
