/// MR1–MR6 stay off until the assistant has passed its release gates.
const bool aiAssistantEnabled = bool.fromEnvironment('MERGELINE_AI_ASSISTANT');

/// Background execution stays off until its native/device release gates pass.
const bool aiBackgroundEnabled = bool.fromEnvironment(
  'MERGELINE_AI_BACKGROUND',
  defaultValue: false,
);
