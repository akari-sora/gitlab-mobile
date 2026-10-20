import '../../core/models.dart';
import 'ai_history.dart';

/// Unconditional account-removal boundary, also when AI is disabled by the gate.
Future<void> clearAiAccountData(Account account) =>
    AiHistoryCoordinator.instance.clearAccount(account.key);
