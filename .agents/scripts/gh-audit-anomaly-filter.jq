# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Fail-closed expected-transition filter for gh-audit-anomaly-helper.sh.

def comparable_state:
  ((.before.capture_status // "ok") == "ok")
  and ((.after.capture_status // "ok") == "ok")
  and ((.delta.comparable // true) == true);

def framework_script($name):
  (.caller_script // "") as $script
  | ["/agents/scripts/", "/.agents/scripts/"]
  | any(.[]; . as $prefix | $script | endswith($prefix + $name));

def expected_approval_transition:
  comparable_state
  and (
    (.op == $issue_edit and .caller_function == "_approval_apply_issue_lifecycle_updates")
    or (.op == "pr_edit" and .caller_function == "_approval_apply_pr_lifecycle_updates")
  )
  and framework_script($approval_script)
  and .flags.approval_verified == "v2-current-state"
  and .suspicious == [("protected_label_removed:" + $nmr)]
  and (.delta.labels_removed // []) == [$nmr]
  and (((.delta.labels_added // []) - ["auto-dispatch"]) | length == 0)
  and (.delta.title_delta_pct == 0)
  and (.delta.body_delta_pct == 0)
  and ((.before.labels // []) | index($nmr) != null)
  and ((.after.labels // []) | index($nmr) == null);

def expected_permission_block_transition:
  comparable_state
  and .op == $issue_edit
  and .caller_function == "permission_apply_block"
  and framework_script($permission_script)
  and ((.after.labels // []) | index($permission) != null)
  and (((.delta.labels_removed // []) | length) > 0)
  and (((.delta.labels_removed // []) - [
    "status:queued", "status:claimed", "status:in-progress", "status:in-review"
  ]) | length == 0)
  and (((.delta.labels_added // []) - [$permission]) | length == 0)
  and (.delta.title_delta_pct == 0)
  and (.delta.body_delta_pct == 0)
  and ([.after.labels[]? | select(
    . == "status:queued"
    or . == "status:claimed"
    or . == "status:in-progress"
    or . == "status:in-review"
  )] | length == 0)
  and ([.before.labels[]? | select(
    . == "status:queued"
    or . == "status:claimed"
    or . == "status:in-progress"
    or . == "status:in-review"
  )] | length > 0)
  and ((.suspicious // []) | length > 0)
  and all(.suspicious[];
    . == "protected_label_removed:status:claimed"
    or . == "protected_label_removed:status:in-progress"
    or . == "protected_label_removed:status:in-review");

def expected_trusted_author_nmr_transition:
  comparable_state
  and .op == $issue_edit
  and .caller_function == "_nmr_edit_issue_labels"
  and framework_script($nmr_script)
  and .flags.trusted_author_nmr_verified == "v1-current-state"
  and .suspicious == [("protected_label_removed:" + $nmr)]
  and (.delta.labels_removed // []) == [$nmr]
  and ((.delta.labels_added // []) == []
    or (.delta.labels_added // []) == ["auto-dispatch"]
    or (.delta.labels_added // []) == ["hold-for-review"])
  and (.delta.title_delta_pct == 0)
  and (.delta.body_delta_pct == 0)
  and ((.before.labels // []) | index($nmr) != null)
  and ((.after.labels // []) | index($nmr) == null);

def expected_full_loop_review_transition:
  comparable_state
  and .op == $issue_edit
  and (
    (.caller_function == "_label_issue_in_review"
      and framework_script($full_loop_commit_script))
    or (.caller_function == "main"
      and framework_script($full_loop_script))
  )
  and .flags.pr_review_handoff_verified == "v1-current-state"
  and .suspicious == ["protected_label_removed:status:in-progress"]
  and (.delta.labels_removed // []) == ["status:in-progress"]
  and (.delta.labels_added // []) == ["status:in-review"]
  and (.delta.title_delta_pct == 0)
  and (.delta.body_delta_pct == 0)
  and ((.before.labels // []) | index("status:in-progress") != null)
  and ((.before.labels // []) | index("status:in-review") == null)
  and ((.after.labels // []) | index("status:in-progress") == null)
  and ((.after.labels // []) | index("status:in-review") != null);

# Snapshot-read failures are observability degradation, not evidence of a
# destructive mutation. Keep them in the immutable audit log, but do not file a
# security-anomaly issue unless the same entry contains another suspicious
# signal. Require the full non-comparable/null-delta shape so malformed or mixed
# records continue to fail closed into the report.
def unavailable_capture_only:
  ((.suspicious // []) | type) == "array"
  and ((.suspicious // []) | length) > 0
  and all(.suspicious[];
    . == "state_capture_unavailable:before"
    or . == "state_capture_unavailable:after")
  and ((.before.capture_status // "ok") == "unavailable"
    or (.after.capture_status // "ok") == "unavailable")
  and (.delta.comparable == false)
  and (.delta.title_delta_pct == null)
  and (.delta.body_delta_pct == null)
  and (.delta.labels_removed == null)
  and (.delta.labels_added == null);

select(try ((.suspicious | length) > 0) catch true)
| select((try (
  expected_approval_transition
  or expected_permission_block_transition
  or expected_trusted_author_nmr_transition
  or expected_full_loop_review_transition
  or unavailable_capture_only
) catch false) | not)
