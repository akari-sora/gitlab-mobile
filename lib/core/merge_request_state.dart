bool isAutoMergeEnabled(Map<String, dynamic> data) {
  if (data['state'] == 'merged' || data['state'] == 'closed') return false;
  return data['merge_when_pipeline_succeeds'] == true ||
      data['auto_merge_enabled'] == true;
}

bool canAutoMerge(Map<String, dynamic> data) {
  if (data['state'] != 'opened' || isAutoMergeEnabled(data)) return false;
  if (data['draft'] == true || data['work_in_progress'] == true) return false;
  if (data['has_conflicts'] == true ||
      data['merge_status'] == 'cannot_be_merged') {
    return false;
  }

  final status = data['detailed_merge_status'];
  if (const [
    'conflict',
    'need_rebase',
    'draft_status',
    'broken_status',
    'not_open',
    'cannot_be_merged',
    'mergeable',
  ].contains(status)) {
    return false;
  }
  if (status == 'ci_still_running' || status == 'ci_must_pass') return true;

  final pipeline = data['head_pipeline'];
  final pipeStatus = pipeline is Map<String, dynamic>
      ? pipeline['status']
      : null;
  return const [
    'running',
    'pending',
    'created',
    'waiting_for_resource',
    'preparing',
    'manual',
  ].contains(pipeStatus);
}
