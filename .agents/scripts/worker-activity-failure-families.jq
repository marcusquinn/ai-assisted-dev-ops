def _wah_empty_if_null: if . == null then "" else . end;
def _wah_failure_family:
  if ((.result // "") | test("rate_limit"))
    or ((.failure_reason // "") | test("rate_limit"))
    or (.provider_status == "429") then "rate-limit"
  elif ((.result // "") | test("watchdog_stall"))
    or (.launch_failure_cause == "stall_hard_killed")
    or (.kill_reason == "hard_kill_stall") then "watchdog-stall"
  elif ((.result // "") | test("recovery"))
    or ((.failure_reason // "") | test("recovery"))
    or ((.next_action // "") | test("recovery")) then "recovery-failure"
  elif (.result == $local_kill_result)
    or (.launch_failure_cause == $local_kill_result)
    or ((.kill_reason // "") | test("kill")) then "local-kill"
  elif (.failure_reason == "local_error")
    or (.launch_failure_cause == "local_runtime_error")
    or ((.runtime_error_type | _wah_empty_if_null) != "") then "local-runtime-error"
  elif ((.launch_failure_cause // "") != "")
    or ((.result // "") | test("launch")) then "launch-failure"
  else "other-failure" end;
def _wah_failure_family_summary:
  map(select(_wah_effective_failure))
  | map(. + {failure_family: _wah_failure_family})
  | group_by(.failure_family)
  | map({
    fingerprint: ("ff-v1:" + .[0].failure_family),
    family: .[0].failure_family,
    launch_failure_cause: ([.[].launch_failure_cause // empty | select(length > 0)][0] // "unknown"),
    kill_reason: ([.[].kill_reason // empty | select(length > 0)][0] // ""),
    next_action: ([.[].next_action // empty | select(length > 0)][0] // ""),
    count: length,
    distinct_sessions: (map((.repo_slug // "legacy") + "|" + (.session_key // (.session_id // "unknown"))) | unique | length),
    first_ts: (map(.ts // 0) | min),
    last_ts: (map(.ts // 0) | max),
    confidence: (if length >= 3 and (map((.repo_slug // "legacy") + "|" + (.session_key // (.session_id // "unknown"))) | unique | length) >= 2 then "high" elif length >= 2 then "medium" else "low" end),
    recovery_outcome: (if length >= 3 then "recurring" else "observed" end),
    results: (reduce .[] as $row ({}; .[$row.result // "unknown"] += 1)),
    examples: (sort_by(.ts // 0) | reverse | .[0:3] | map({ts, result, exit_code, launch_failure_cause, kill_reason, next_action}))
  })
  | sort_by(.count) | reverse | .[0:10];
