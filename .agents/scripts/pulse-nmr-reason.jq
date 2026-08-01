def metadata($code; $class; $source): {
  code: $code,
  class: $class,
  source: $source,
  revalidate_after_seconds: (if $class == "temporary" then $revalidate else null end),
  requires_crypto: ($class == "genuine-authority")
};
def explicit_metadata:
  try capture("<!--\\s*nmr-reason\\s+code=(?<code>[a-z_-]+)\\s+class=(?<class>genuine-authority|temporary)\\s*-->")
  catch null;
def legacy_metadata:
  ascii_downcase as $text
  | if ($text | test("<!--\\s*(cost-circuit-breaker:(fired|no_work_loop)|billing-approval-required)\\b")) then metadata("billing"; "genuine-authority"; "legacy-marker")
    elif ($text | test("<!--\\s*(secret-required|credential-access-required)\\b")) then metadata("secret"; "genuine-authority"; "legacy-marker")
    elif ($text | test("<!--\\s*(destructive-approval-required|irreversible-operation)\\b")) then metadata("destructive"; "genuine-authority"; "legacy-marker")
    elif ($text | test("<!--\\s*(security-sensitive|auth-boundary-approval-required)\\b")) then metadata("security"; "genuine-authority"; "legacy-marker")
    elif ($text | test("<!--\\s*(dispatch-backoff:rate_limit_nmr|dispatch-infrastructure-failure|transient-infrastructure)\\b")) then metadata("transient_infrastructure"; "temporary"; "legacy-marker")
    elif ($text | test("<!--\\s*(missing-implementation-context|missing-context)\\b")) then metadata("missing_context"; "temporary"; "legacy-marker")
    elif ($text | test("<!--\\s*(stale-recovery-tick:escalated|dispatch-circuit-breaker:worker_recovery_loop|diagnostic-ambiguity)\\b")) then metadata("diagnostic_ambiguity"; "temporary"; "legacy-marker")
    else null end;
(if type == "array" and (.[0]? | type) == "array" then [.[][]]
 else if type == "array" then . else [] end end) as $comments
| ([$comments[].body // "" | explicit_metadata | select(. != null)] | last) as $explicit
| ([$comments[].body // "" | legacy_metadata | select(. != null)] | last) as $legacy
| if $explicit != null then metadata($explicit.code; $explicit.class; "structured-marker")
  elif $legacy != null then $legacy
  else metadata("authority"; "genuine-authority"; "default") end
