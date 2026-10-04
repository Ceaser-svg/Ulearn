import 'package:flutter/material.dart';

/// Asks an operator why a competency is being rejected.
///
/// The API requires a reason for a rejection and a tutor cannot act on a
/// refusal that does not say what to fix, so the dialog will not close on an
/// empty answer. `scrollable` keeps the field reachable when the platform
/// scales its text up.
class RejectionReasonDialog extends StatefulWidget {
  const RejectionReasonDialog({super.key});

  @override
  State<RejectionReasonDialog> createState() => _RejectionReasonDialogState();
}

class _RejectionReasonDialogState extends State<RejectionReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject competency'),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'Reason',
          hintText: 'Explain what needs to be corrected.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Reject')),
      ],
    );
  }
}
