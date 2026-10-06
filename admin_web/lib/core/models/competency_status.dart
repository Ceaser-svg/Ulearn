/// Where a competency stands, as the API's `CompetencyStatus` names it.
///
/// Typed rather than a bare string so that the review actions, the chip, and
/// the filter are all reading the same set of values, and so a screen cannot
/// compare a status against a misspelling that silently never matches.
enum CompetencyStatus {
  pending('pending', 'Pending'),
  verified('verified', 'Verified'),
  rejected('rejected', 'Rejected'),

  /// A status this build of the console does not know.
  ///
  /// Reached through [CompetencyStatus.parse] when the API sends a value added
  /// after this client shipped. It is not an error: the server owns the rule and
  /// a newer server may legitimately have added a state. Modelling it as a
  /// failure would mean a pilot operator sees "could not load" because the
  /// backend moved on, which is exactly the wrong place to discover a deploy.
  unknown('unknown', 'Unknown');

  CompetencyStatus(this.wire, this.label);

  /// The value sent over the wire.
  final String wire;

  /// What an operator reads.
  final String label;

  /// Whether the server named this status, as opposed to [unknown] standing in
  /// for one this build has never heard of.
  bool get isKnown => this != CompetencyStatus.unknown;

  /// True for the one status an operator can act on.
  ///
  /// Every other status is a decision already made, so offering a button would
  /// invite a second decision on a record the server has moved on from.
  bool get isReviewable => this == CompetencyStatus.pending;

  /// The status [raw] names, or [unknown] if this build has never heard of it.
  static CompetencyStatus parse(String raw) => switch (raw) {
    'pending' => CompetencyStatus.pending,
    'verified' => CompetencyStatus.verified,
    'rejected' => CompetencyStatus.rejected,
    _ => CompetencyStatus.unknown,
  };

  /// Every status worth offering as a filter, in the order an operator works
  /// the queue: what is waiting, then what was decided each way.
  static const List<CompetencyStatus> filterable = <CompetencyStatus>[
    CompetencyStatus.pending,
    CompetencyStatus.rejected,
    CompetencyStatus.verified,
  ];
}
