import 'package:flutter/material.dart';

import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'picker_sheet.dart';

import '../../l10n/l10n.dart';
enum WorkItemOrderBy { createdAt, updatedAt, dueDate }

enum WorkItemSort { asc, desc }

enum WorkItemScope { all, assignedToMe, createdByMe, reviewsForMe }

extension on WorkItemOrderBy {
  String get api => switch (this) {
    WorkItemOrderBy.createdAt => 'created_at',
    WorkItemOrderBy.updatedAt => 'updated_at',
    WorkItemOrderBy.dueDate => 'due_date',
  };

  String get label => switch (this) {
    WorkItemOrderBy.createdAt => l10n.createdDate2,
    WorkItemOrderBy.updatedAt => l10n.updatedDate,
    WorkItemOrderBy.dueDate => l10n.dueDate2,
  };
}

extension on WorkItemSort {
  String get api => name;
  String get label => this == WorkItemSort.asc ? l10n.oldestFirst2 : l10n.newestFirst2;
}

extension on WorkItemScope {
  String get api => switch (this) {
    WorkItemScope.all => 'all',
    WorkItemScope.assignedToMe => 'assigned_to_me',
    WorkItemScope.createdByMe => 'created_by_me',
    WorkItemScope.reviewsForMe => 'reviews_for_me',
  };

  String get label => switch (this) {
    WorkItemScope.all => l10n.everyone,
    WorkItemScope.assignedToMe => l10n.assignedToMe,
    WorkItemScope.createdByMe => l10n.createdByMe,
    WorkItemScope.reviewsForMe => l10n.needsMyReview,
  };
}

class WorkItemFilters {
  const WorkItemFilters({
    this.orderBy = WorkItemOrderBy.updatedAt,
    this.sort = WorkItemSort.desc,
    this.scope = WorkItemScope.all,
    this.labels = const [],
    this.milestone,
    this.assignee,
    this.author,
    this.reviewer,
  });

  final WorkItemOrderBy orderBy;
  final WorkItemSort sort;
  final WorkItemScope scope;
  final List<PickerChoice> labels;
  final PickerChoice? milestone, assignee, author, reviewer;

  Map<String, String> toQuery({required bool mergeRequest}) => {
    'scope': scope == WorkItemScope.reviewsForMe && !mergeRequest
        ? WorkItemScope.all.api
        : scope.api,
    'order_by': orderBy == WorkItemOrderBy.dueDate && mergeRequest
        ? WorkItemOrderBy.updatedAt.api
        : orderBy.api,
    'sort': sort.api,
    if (labels.isNotEmpty)
      'labels': labels.map((choice) => choice.name).join(','),
    if (milestone != null) 'milestone': milestone!.name,
    if (assignee != null) 'assignee_id': assignee!.id,
    if (author != null) 'author_id': author!.id,
    if (mergeRequest && reviewer != null) 'reviewer_id': reviewer!.id,
  };

  String identity({required bool mergeRequest}) =>
      Uri(queryParameters: toQuery(mergeRequest: mergeRequest)).query;

  int activeCount({required bool mergeRequest}) {
    var count = 0;
    if (orderBy != WorkItemOrderBy.updatedAt || sort != WorkItemSort.desc) {
      count++;
    }
    if (scope != WorkItemScope.all) count++;
    if (labels.isNotEmpty) count++;
    if (milestone != null) count++;
    if (assignee != null) count++;
    if (author != null) count++;
    if (mergeRequest && reviewer != null) count++;
    return count;
  }

  bool get canPrependCreated =>
      sort == WorkItemSort.desc && orderBy != WorkItemOrderBy.dueDate;

  bool matches(
    Json item, {
    required int userId,
    required bool mergeRequest,
    String search = '',
  }) {
    final needle = search.trim().toLowerCase();
    if (needle.isNotEmpty) {
      final title = valueText(item, 'title').toLowerCase();
      final description = valueText(item, 'description').toLowerCase();
      if (!title.contains(needle) && !description.contains(needle)) {
        return false;
      }
    }
    final itemLabels = <String>{};
    final rawLabels = item['labels'];
    if (rawLabels is List<dynamic>) {
      for (final value in rawLabels) {
        if (value is String) {
          itemLabels.add(value.toLowerCase());
        } else if (value is Map<String, dynamic>) {
          itemLabels.add(valueText(value, 'name').toLowerCase());
        }
      }
    }
    if (labels.any(
      (choice) => !itemLabels.contains(choice.name.toLowerCase()),
    )) {
      return false;
    }
    if (milestone != null &&
        valueText(valueObject(item, 'milestone'), 'title') != milestone!.name) {
      return false;
    }
    final assignees = valueObjects(item, 'assignees');
    final reviewers = valueObjects(item, 'reviewers');
    final authorId = valueInt(valueObject(item, 'author'), 'id');
    bool contains(List<Json> people, String id) =>
        people.any((person) => '${valueInt(person, 'id')}' == id);
    if (assignee != null && !contains(assignees, assignee!.id)) return false;
    if (author != null && '$authorId' != author!.id) return false;
    if (mergeRequest &&
        reviewer != null &&
        !contains(reviewers, reviewer!.id)) {
      return false;
    }
    return switch (scope) {
      WorkItemScope.all => true,
      WorkItemScope.assignedToMe => assignees.any(
        (person) => valueInt(person, 'id') == userId,
      ),
      WorkItemScope.createdByMe => authorId == userId,
      WorkItemScope.reviewsForMe =>
        mergeRequest &&
            reviewers.any((person) => valueInt(person, 'id') == userId),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is WorkItemFilters &&
      orderBy == other.orderBy &&
      sort == other.sort &&
      scope == other.scope &&
      _sameChoices(labels, other.labels) &&
      _sameChoice(milestone, other.milestone) &&
      _sameChoice(assignee, other.assignee) &&
      _sameChoice(author, other.author) &&
      _sameChoice(reviewer, other.reviewer);

  @override
  int get hashCode => Object.hash(
    orderBy,
    sort,
    scope,
    Object.hashAll(labels.map((choice) => choice.id)),
    milestone?.id,
    assignee?.id,
    author?.id,
    reviewer?.id,
  );
}

bool _sameChoice(PickerChoice? a, PickerChoice? b) =>
    a?.id == b?.id && a?.name == b?.name;
bool _sameChoices(List<PickerChoice> a, List<PickerChoice> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (!_sameChoice(a[index], b[index])) return false;
  }
  return true;
}

Future<WorkItemFilters?> showWorkItemFilters(
  BuildContext context, {
  required GitLabApi api,
  required Account account,
  required int projectId,
  required bool mergeRequest,
  required WorkItemFilters initial,
  ValueChanged<Route<dynamic>>? onRoute,
}) {
  final navigator = Navigator.of(context);
  final localizations = MaterialLocalizations.of(context);
  final route = ModalBottomSheetRoute<WorkItemFilters>(
    capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    isScrollControlled: true,
    useSafeArea: true,
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
    modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .92,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: WorkItemFilterSheet(
            api: api,
            account: account,
            projectId: projectId,
            mergeRequest: mergeRequest,
            initial: initial,
          ),
        ),
      ),
    ),
  );
  onRoute?.call(route);
  return navigator.push(route);
}

class WorkItemFilterSheet extends StatefulWidget {
  const WorkItemFilterSheet({
    super.key,
    required this.api,
    required this.account,
    required this.projectId,
    required this.mergeRequest,
    required this.initial,
  });
  final GitLabApi api;
  final Account account;
  final int projectId;
  final bool mergeRequest;
  final WorkItemFilters initial;
  @override
  State<WorkItemFilterSheet> createState() => _WorkItemFilterSheetState();
}

class _WorkItemFilterSheetState extends State<WorkItemFilterSheet> {
  late WorkItemOrderBy _orderBy;
  late WorkItemSort _sort;
  late WorkItemScope _scope;
  late List<PickerChoice> _labels;
  PickerChoice? _milestone, _assignee, _author, _reviewer;

  @override
  void initState() {
    super.initState();
    _load(widget.initial);
  }

  void _load(WorkItemFilters value) {
    _orderBy = value.orderBy == WorkItemOrderBy.dueDate && widget.mergeRequest
        ? WorkItemOrderBy.updatedAt
        : value.orderBy;
    _sort = value.sort;
    _scope = value.scope == WorkItemScope.reviewsForMe && !widget.mergeRequest
        ? WorkItemScope.all
        : value.scope;
    _labels = [...value.labels];
    _milestone = value.milestone;
    _assignee = value.assignee;
    _author = value.author;
    _reviewer = value.reviewer;
  }

  WorkItemFilters get _value => WorkItemFilters(
    orderBy: _orderBy,
    sort: _sort,
    scope: _scope,
    labels: List<PickerChoice>.unmodifiable(_labels),
    milestone: _milestone,
    assignee: _assignee,
    author: _author,
    reviewer: widget.mergeRequest ? _reviewer : null,
  );

  Future<void> _pick(
    PickerSource source, {
    required String title,
    required bool multi,
    _MemberFilter? member,
  }) async {
    final initial = switch (source) {
      PickerSource.labels => _labels,
      PickerSource.milestones => [?_milestone],
      PickerSource.members when member == _MemberFilter.assignee => [?_assignee],
      PickerSource.members when member == _MemberFilter.author => [?_author],
      PickerSource.members => [?_reviewer],
      PickerSource.branches => const <PickerChoice>[],
    };
    final selected = await showChoicePicker(
      context,
      api: widget.api,
      account: widget.account,
      projectId: widget.projectId,
      source: source,
      multi: multi,
      title: title,
      initial: initial,
    );
    if (selected == null || !mounted) return;
    setState(() {
      switch (source) {
        case PickerSource.labels:
          _labels = selected;
        case PickerSource.milestones:
          _milestone = selected.firstOrNull;
        case PickerSource.members when member == _MemberFilter.assignee:
          _assignee = selected.firstOrNull;
        case PickerSource.members when member == _MemberFilter.author:
          _author = selected.firstOrNull;
        case PickerSource.members:
          _reviewer = selected.firstOrNull;
        case PickerSource.branches:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('work-item-filter-sheet'),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.filterAndSort,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: l10n.closeAction,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            DropdownButtonFormField<WorkItemOrderBy>(
              key: const Key('filter-order-by'),
              initialValue: _orderBy,
              decoration: InputDecoration(
                labelText: l10n.sortBy2,
                prefixIcon: Icon(Icons.sort),
              ),
              items:
                  [
                        WorkItemOrderBy.createdAt,
                        WorkItemOrderBy.updatedAt,
                        if (!widget.mergeRequest) WorkItemOrderBy.dueDate,
                      ]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                      )
                      .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _orderBy = value);
              },
            ),
            const SizedBox(height: 12),
            Text(l10n.sortDirection2, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final value in WorkItemSort.values)
                  ChoiceChip(
                    key: Key('filter-sort-${value.name}'),
                    label: Text(value.label),
                    selected: _sort == value,
                    onSelected: (_) => setState(() => _sort = value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.quickFilters, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final value in WorkItemScope.values)
                  if (value != WorkItemScope.reviewsForMe ||
                      widget.mergeRequest)
                    ChoiceChip(
                      key: Key(
                        'filter-scope-${switch (value) {
                          WorkItemScope.all => 'all',
                          WorkItemScope.assignedToMe => 'assigned',
                          WorkItemScope.createdByMe => 'created',
                          WorkItemScope.reviewsForMe => 'review',
                        }}',
                      ),
                      label: Text(value.label),
                      selected: _scope == value,
                      onSelected: (_) => setState(() => _scope = value),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            _pickerTile(
              const Key('filter-labels'),
              Icons.label_outline,
              l10n.labelNoun,
              _labels,
              () => _pick(PickerSource.labels, title: l10n.labelNoun, multi: true),
            ),
            _pickerTile(
              const Key('filter-milestone'),
              Icons.tour_outlined,
              l10n.milestoneLabel,
              [?_milestone],
              () => _pick(PickerSource.milestones, title: l10n.milestoneLabel, multi: false),
            ),
            _pickerTile(
              const Key('filter-assignee'),
              Icons.assignment_ind_outlined,
              l10n.assigneeFilter,
              [?_assignee],
              () => _pick(PickerSource.members, title: l10n.assigneeFilter, multi: false, member: _MemberFilter.assignee),
            ),
            _pickerTile(
              const Key('filter-author'),
              Icons.person_outline,
              l10n.author,
              [?_author],
              () => _pick(PickerSource.members, title: l10n.author, multi: false, member: _MemberFilter.author),
            ),
            if (widget.mergeRequest)
              _pickerTile(
                const Key('filter-reviewer'),
                Icons.rate_review_outlined,
                l10n.reviewer,
                [?_reviewer],
                () => _pick(PickerSource.members, title: l10n.reviewer, multi: false, member: _MemberFilter.reviewer),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            TextButton(
              key: const Key('filter-cancel'),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancelAction),
            ),
            TextButton(
              key: const Key('filter-reset'),
              onPressed: () => setState(() => _load(const WorkItemFilters())),
              child: Text(l10n.reset),
            ),
            const Spacer(),
            FilledButton(
              key: const Key('filter-apply'),
              onPressed: () => Navigator.pop(context, _value),
              child: Text(l10n.apply),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _pickerTile(
    Key key,
    IconData icon,
    String title,
    List<PickerChoice> selected,
    VoidCallback onTap,
  ) => ListTile(
    key: key,
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(
      selected.isEmpty
          ? l10n.anyFilter
          : selected
                .map(
                  (choice) => choice.username == null
                      ? choice.name
                      : '@${choice.username}',
                )
                .join(l10n.listSeparator),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

/// Which member filter a picker fills; the title is only for display.
enum _MemberFilter { assignee, author, reviewer }
