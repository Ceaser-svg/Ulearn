import 'package:flutter/material.dart';

/// Asks an operator why a competency is being rejected.
///
/// The API requires a reason for a rejection and a tutor cannot act on a refusal
/// that does not say what to fix, so the dialog will not close on an empty answer.
/// The old version did return an empty string, and the screen dropped it -- so an
/// operator who tapped Reject and left the field blank got no message at all, and
/// no way to tell a deliberate cancellation from a forgotten field. The reason is
/// asked here, where the operator can see it is required.
///
/// `scrollable` keeps the field reachable when the platform scales its text up.
class RejectionReasonDialog extends StatefulWidget {
  const RejectionReasonDialog({super.key});

  /// The API's limit, from `MAX_EVIDENCE_REFERENCE_LENGTH`.
  ///
  /// Enforced here as well as on the server so an operator is told the reason is
  /// too long before the request, rather than after a 422 they cannot predict. The
  /// server still owns the rule; this only avoids the round trip.
  static const int maxReasonLength = 500;

  @override
  State<RejectionReasonDialog> createState() => _RejectionReasonDialogState();
}

class _RejectionReasonDialogState extends State<RejectionReasonDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Whether what is typed is a reason the API will accept.
  bool get _isValid => _controller.text.trim().isNotEmpty;

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      // Said here rather than swallowed, because the operator has asked to reject
      // something and has not yet said why.
      setState(() => _error = 'A reason is required so the tutor knows what to fix.');
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reject competency'),
      scrollable: true,
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: RejectionReasonDialog.maxReasonLength,
        textInputAction: TextInputAction.done,
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Reason',
          hintText: 'Explain what needs to be corrected.',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid ? _submit : null,
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
