/// Autonomy levels and write tiers, shared by the account settings, the
/// consent and the write gate. One declaration, so every layer compares the
/// same values.
library;

/// Starting level and ceiling, lowest to highest.
enum AiAutonomyLevel {
  readOnly,
  confirmEach,
  lowRiskAuto,
  conversationGrant,
  bypass,
}

enum AiWriteTier { t1, t2, t3, t4, hardLine }
