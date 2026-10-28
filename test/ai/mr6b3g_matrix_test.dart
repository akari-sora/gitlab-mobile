import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/intent_lexicon.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';

import 'mr6b3g_support.dart';

// Policy tests use the real production rows and effective production gate.
// They exercise tier decisions, not the family HTTP implementations.
const _tiers = <String, AiWriteTier>{
  'updateGroupWorkItemState': AiWriteTier.t2,
  'updateGroupWorkItemStatus': AiWriteTier.t2,
  'updateGroupWorkItemDates': AiWriteTier.t2,
  'updateGroupWorkItemHealthStatus': AiWriteTier.t2,
  'updateGroupWorkItemAssignees': AiWriteTier.t2,
  'updateGroupWorkItemMilestone': AiWriteTier.t2,
  'updateGroupWorkItemWeight': AiWriteTier.t2,
  'updateGroupWorkItemLabels': AiWriteTier.t2,
  'updateGroupWorkItemContent': AiWriteTier.t2,
  'createGroupWorkItemActivityComment': AiWriteTier.t2,
  'createGroupWorkItemActivityReply': AiWriteTier.t2,
  'editGroupWorkItemActivityNote': AiWriteTier.t2,
  'deleteGroupWorkItemActivityNote': AiWriteTier.t4,
  'setGroupWorkItemActivityNoteReaction': AiWriteTier.t1,
  'setGroupWorkItemNotifications': AiWriteTier.t1,
};
final _aliases = _tiers.keys;

// Independently pinned phrases from the T1 family corpus.
const _localeDirections =
    <({String locale, String add, String remove, String on, String off})>[
      (
        locale: 'ar',
        add: 'تفاعل مع التعليق',
        remove: 'أزل تفاعل التعليق',
        on: 'فعّل الإشعارات',
        off: 'أوقف الإشعارات',
      ),
      (
        locale: 'cs',
        add: 'reakce na komentar',
        remove: 'odebrat reakci',
        on: 'zapnout upozorneni',
        off: 'vypnout upozorneni',
      ),
      (
        locale: 'de',
        add: 'Kommentarreaktion setzen',
        remove: 'Kommentarreaktion entfernen',
        on: 'Benachrichtigungen einschalten',
        off: 'Benachrichtigungen ausschalten',
      ),
      (
        locale: 'en',
        add: 'react to the comment',
        remove: 'remove the comment reaction',
        on: 'turn notifications on',
        off: 'turn notifications off',
      ),
      (
        locale: 'es',
        add: 'reaccionar al comentario',
        remove: 'quitar reaccion del comentario',
        on: 'activar notificaciones',
        off: 'desactivar notificaciones',
      ),
      (
        locale: 'fr',
        add: 'reagir au commentaire',
        remove: 'retirer la reaction',
        on: 'activer les notifications',
        off: 'desactiver les notifications',
      ),
      (
        locale: 'hi',
        add: 'टिप्पणी पर प्रतिक्रिया',
        remove: 'टिप्पणी की प्रतिक्रिया हटाओ',
        on: 'सूचनाएँ चालू करो',
        off: 'सूचनाएँ बंद करो',
      ),
      (
        locale: 'id',
        add: 'reaksi pada komentar',
        remove: 'hapus reaksi',
        on: 'nyalakan notifikasi',
        off: 'matikan notifikasi',
      ),
      (
        locale: 'it',
        add: 'reagisci al commento',
        remove: 'rimuovi reazione',
        on: 'attiva notifiche',
        off: 'disattiva notifiche',
      ),
      (
        locale: 'ja',
        add: 'コメントに絵文字を付ける',
        remove: 'コメントの絵文字を外す',
        on: '通知をオンにする',
        off: '通知をオフにする',
      ),
      (
        locale: 'ko',
        add: '댓글에 이모지 추가',
        remove: '댓글 이모지 제거',
        on: '알림 켜기',
        off: '알림 끄기',
      ),
      (
        locale: 'ms',
        add: 'reaksi pada komen',
        remove: 'padam reaksi',
        on: 'hidupkan pemberitahuan',
        off: 'matikan pemberitahuan',
      ),
      (
        locale: 'nl',
        add: 'reactie op opmerking',
        remove: 'reactie weghalen',
        on: 'meldingen aan',
        off: 'meldingen uit',
      ),
      (
        locale: 'pl',
        add: 'reakcja do komentarza',
        remove: 'usun reakcje',
        on: 'wlacz powiadomienia',
        off: 'wylacz powiadomienia',
      ),
      (
        locale: 'pt-BR',
        add: 'reagir ao comentario',
        remove: 'remover reacao do comentario',
        on: 'ativar notificacoes',
        off: 'desativar notificacoes',
      ),
      (
        locale: 'ro',
        add: 'reactie la comentariu',
        remove: 'elimina reactia',
        on: 'activeaza notificarile',
        off: 'dezactiveaza notificarile',
      ),
      (
        locale: 'ru',
        add: 'реакция на комментарий',
        remove: 'убрать реакцию',
        on: 'включить уведомления',
        off: 'выключить уведомления',
      ),
      (
        locale: 'sv',
        add: 'reagera pa kommentar',
        remove: 'ta bort reaktion',
        on: 'aktivera aviseringar',
        off: 'stang av aviseringar',
      ),
      (
        locale: 'th',
        add: 'แสดงความรู้สึกที่ความคิดเห็น',
        remove: 'เอาความรู้สึกออก',
        on: 'เปิดการแจ้งเตือน',
        off: 'ปิดการแจ้งเตือน',
      ),
      (
        locale: 'tr',
        add: 'yoruma tepki ekle',
        remove: 'yorum tepkisini kaldir',
        on: 'bildirimleri ac',
        off: 'bildirimleri kapat',
      ),
      (
        locale: 'uk',
        add: 'реакція на коментар',
        remove: 'прибрати реакцію',
        on: 'увімкнути сповіщення',
        off: 'вимкнути сповіщення',
      ),
      (
        locale: 'vi',
        add: 'thả cảm xúc bình luận',
        remove: 'xóa cảm xúc bình luận',
        on: 'bật thông báo',
        off: 'tắt thông báo',
      ),
      (
        locale: 'zh-CN',
        add: '评论添加表情',
        remove: '评论移除表情',
        on: '开启通知',
        off: '关闭通知',
      ),
      (
        locale: 'zh-TW',
        add: '留言加上表情',
        remove: '留言移除表情',
        on: '開啟通知',
        off: '關閉通知',
      ),
    ];

AiTierDecision _decide(
  String operation,
  AiAutonomyLevel level, {
  bool bound = true,
  bool intent = true,
  AiTierFacts facts = const AiTierFacts(),
}) => decideTier(
  AiTierInput(
    level: level,
    capability: productionAiLedger.find(operation)!,
    scope: g0eScope,
    binding: AiBindingResult(
      userMessage: 'Synthetic explicit user request',
      allBound: bound,
      intentAuthorizesLowRisk: intent,
    ),
    target: AiTargetRef(
      kind: AiTargetKind.groupWorkItem,
      groupId: 7,
      groupFullPath: g0ePath,
      iid: 5,
    ),
    typedName: '$g0ePath#5',
    facts: facts,
  ),
);

void main() {
  setUp(() {
    expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
    expect(aiGroupWorkItemWritesAreEnabled, isTrue);
  });

  test('all fifteen actual group rows are visible and retain their tiers', () {
    expect(_aliases, hasLength(15));
    for (final name in _aliases) {
      final row = productionAiLedger.find(name);
      expect(row, isNotNull, reason: name);
      expect(row!.modelVisible, isTrue, reason: name);
      expect(row.baseTier, _tiers[name], reason: name);
      expect(row.scopeClass, AiScopeClass.groupWorkItem, reason: name);
      expect(row.boundary, AiWriteBoundary.graph, reason: name);
    }
    expect(aiGroupWorkItemWritesEnabled, isTrue);
  });

  for (final name in _aliases) {
    for (final level in AiAutonomyLevel.values) {
      test('$name ${level.name} applies the five-level group policy', () {
        final decision = _decide(name, level);
        final tier = _tiers[name]!;
        final expected = switch ((level, tier)) {
          (AiAutonomyLevel.readOnly, _) => AiGateDecision.deny,
          (AiAutonomyLevel.confirmEach, _) => AiGateDecision.requireApproval,
          (AiAutonomyLevel.lowRiskAuto, AiWriteTier.t1) =>
            AiGateDecision.execute,
          (AiAutonomyLevel.lowRiskAuto, _) => AiGateDecision.requireApproval,
          (
            AiAutonomyLevel.conversationGrant,
            AiWriteTier.t1 || AiWriteTier.t2,
          ) =>
            AiGateDecision.execute,
          (AiAutonomyLevel.conversationGrant, _) =>
            AiGateDecision.requireApproval,
          (AiAutonomyLevel.bypass, AiWriteTier.hardLine) =>
            AiGateDecision.requireApproval,
          (AiAutonomyLevel.bypass, _) => AiGateDecision.execute,
        };
        expect(decision.tier, tier);
        expect(decision.decision, expected);
        if (tier == AiWriteTier.t4 &&
            expected == AiGateDecision.requireApproval) {
          expect(decision.requiresTypedName, isTrue);
          expect(decision.typedName, '$g0ePath#5');
        }
      });
    }
  }

  for (final name in _aliases) {
    test('$name bypass still confirms an unbound target', () {
      final result = _decide(name, AiAutonomyLevel.bypass, bound: false);
      expect(result.decision, AiGateDecision.requireApproval);
      expect(result.reasons, contains(AiFixedConfirmReason.targetUnbound));
    });
  }

  for (final name in [
    'setGroupWorkItemNotifications',
    'setGroupWorkItemActivityNoteReaction',
  ]) {
    test('$name low risk automatic requires trusted directional intent', () {
      final result = _decide(name, AiAutonomyLevel.lowRiskAuto, intent: false);
      expect(result.decision, AiGateDecision.requireApproval);
      expect(result.reasons, contains(AiFixedConfirmReason.intentNotUnique));
    });
  }

  test('24 locale directions cover all supported app languages', () {
    expect(
      _localeDirections.map((row) => row.locale),
      unorderedEquals(appLanguages.map((language) => language.tag)),
    );
    expect(_localeDirections, hasLength(24));
  });

  for (final row in _localeDirections) {
    test(
      'production group T1 directions and adversarial phrases: ${row.locale}',
      () {
        final language = languageForTag(row.locale)!;
        for (final entry in [
          (
            op: 'setGroupWorkItemActivityNoteReaction',
            key: 'add',
            value: true,
            phrase: row.add,
            direction: AiIntentDirection.workItemReactionAdd,
          ),
          (
            op: 'setGroupWorkItemActivityNoteReaction',
            key: 'add',
            value: false,
            phrase: row.remove,
            direction: AiIntentDirection.workItemReactionRemove,
          ),
          (
            op: 'setGroupWorkItemNotifications',
            key: 'enabled',
            value: true,
            phrase: row.on,
            direction: AiIntentDirection.workItemNotificationsOn,
          ),
          (
            op: 'setGroupWorkItemNotifications',
            key: 'enabled',
            value: false,
            phrase: row.off,
            direction: AiIntentDirection.workItemNotificationsOff,
          ),
        ]) {
          final args = <String, Object?>{
            'groupId': 7,
            'iid': 5,
            entry.key: entry.value,
            if (entry.key == 'add') ...{'noteId': 31, 'name': 'thumbsup'},
          };
          expect(
            requestedIntentDirection(entry.op, args, null),
            entry.direction,
          );
          expect(
            AiIntentLexicon.phrases(language, entry.direction),
            contains(entry.phrase),
          );
          AiIntentAssessment assess(String message, {bool restored = false}) =>
              assessIntent(
                message: message,
                restoredFromHistory: restored,
                operationId: entry.op,
                interfaceLanguage: row.locale,
                deviceLanguages: const [],
                arguments: args,
              );
          final trusted = assess(entry.phrase);
          expect(
            trusted.authorizes,
            isTrue,
            reason: '${row.locale}: ${entry.phrase}',
          );
          expect(
            _decide(
              entry.op,
              AiAutonomyLevel.lowRiskAuto,
              intent: trusted.authorizes,
            ).decision,
            AiGateDecision.execute,
          );
          final opposite = AiIntentLexicon.phrases(
            language,
            oppositeIntent(entry.direction)!,
          ).first;
          for (final unclear in [
            opposite,
            '${entry.phrase}; $opposite',
            '${AiIntentLexicon.negations(language).first} ${entry.phrase}',
            '${AiIntentLexicon.conditions(language).first} ${entry.phrase}',
            '> ${entry.phrase}',
            '`${entry.phrase}`',
            '```\n${entry.phrase}\n```',
          ]) {
            final result = assess(unclear);
            expect(
              result.authorizes,
              isFalse,
              reason: '${row.locale}: $unclear',
            );
            final gate = _decide(
              entry.op,
              AiAutonomyLevel.lowRiskAuto,
              intent: result.authorizes,
            );
            expect(gate.decision, AiGateDecision.requireApproval);
            expect(
              gate.reasons,
              contains(AiFixedConfirmReason.intentNotUnique),
            );
          }
          final restored = assess(entry.phrase, restored: true);
          expect(restored.authorizes, isFalse);
          expect(
            _decide(
              entry.op,
              AiAutonomyLevel.lowRiskAuto,
              intent: restored.authorizes,
            ).decision,
            AiGateDecision.requireApproval,
          );
        }
      },
    );
  }

  const alwaysConfirm = <AiFixedConfirmReason>{
    AiFixedConfirmReason.markAllTodosDone,
    AiFixedConfirmReason.foreignDraftsInPublish,
    AiFixedConfirmReason.massMention,
    AiFixedConfirmReason.externalMediaInRenderedMarkdown,
    AiFixedConfirmReason.foreignClosingOrCrossProject,
    AiFixedConfirmReason.duplicateOfSettledWrite,
    AiFixedConfirmReason.duplicateUpload,
    AiFixedConfirmReason.wholeFieldDropsHiddenSpans,
  };
  test('always-confirm inventory matches the independent contract', () {
    expect(aiAlwaysConfirmReasons, alwaysConfirm);
  });
  for (final reason in alwaysConfirm) {
    for (final level in AiAutonomyLevel.values) {
      test('fixed $reason at ${level.name} remains confirmation', () {
        final result = _decide(
          'updateGroupWorkItemState',
          level,
          facts: AiTierFacts(reasons: [reason]),
        );
        expect(
          result.decision,
          level == AiAutonomyLevel.readOnly
              ? AiGateDecision.deny
              : AiGateDecision.requireApproval,
        );
        if (level != AiAutonomyLevel.readOnly) {
          expect(result.reasons, contains(reason));
        }
      });
    }
  }

  for (final level in AiAutonomyLevel.values) {
    for (final operation in ['createPipeline', 'forkProject']) {
      test(
        '$operation hard floor at ${level.name} and unavailable to group',
        () {
          final row = productionAiLedger.find(operation)!;
          const scope = AiWriteScope(
            accountKey: g0eAccount,
            grants: [
              AiScopeGrant(
                kind: AiScopeKind.project,
                projectId: 9,
                projectPath: 'team/project',
              ),
            ],
          );
          final decision = decideTier(
            AiTierInput(
              level: level,
              capability: row,
              scope: scope,
              binding: const AiBindingResult(
                userMessage: 'Explicit request',
                allBound: true,
                intentAuthorizesLowRisk: true,
              ),
              target: AiTargetRef(kind: AiTargetKind.project, projectId: 9),
              typedName: 'team/project',
              facts: operation == 'createPipeline'
                  ? const AiTierFacts(pipelineVariables: true)
                  : const AiTierFacts(),
            ),
          );
          expect(decision.tier, AiWriteTier.hardLine);
          expect(
            decision.decision,
            level == AiAutonomyLevel.readOnly
                ? AiGateDecision.deny
                : AiGateDecision.requireApproval,
          );
          if (level != AiAutonomyLevel.readOnly) {
            expect(decision.requiresTypedName, isTrue);
            expect(decision.typedName, 'team/project');
          }
          expect(
            toolsForScope(g0eScope).map((item) => item.operationId),
            isNot(contains(operation)),
          );
        },
      );
    }
  }

  for (final facts in [
    const AiTierFacts(confidentialLowered: true),
    const AiTierFacts(visibilityRaised: true),
    const AiTierFacts(touchesCiConfig: true),
  ]) {
    for (final level in AiAutonomyLevel.values) {
      test(
        'hard-line fact $facts at ${level.name} remains typed confirmation',
        () {
          final result = _decide(
            'updateGroupWorkItemState',
            level,
            facts: facts,
          );
          expect(result.tier, AiWriteTier.hardLine);
          if (level == AiAutonomyLevel.readOnly) {
            expect(result.decision, AiGateDecision.deny);
          } else {
            expect(result.decision, AiGateDecision.requireApproval);
            expect(result.requiresTypedName, isTrue);
          }
        },
      );
    }
  }
}
