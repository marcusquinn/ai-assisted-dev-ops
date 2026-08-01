def run_key:
  [(.name // ""), (.app.slug // .app.name // ""), (.workflow_run_id // "")];

def run_time:
  .created_at // .started_at // .updated_at // .completed_at // "";

def run_id:
  if (.id | type) == "number" then .id else 0 end;

def latest_by_key:
  sort_by(run_key)
  | group_by(run_key)
  | map(max_by([run_id, run_time]));

def postflight_advisory_reason:
  if ((.name // "") == "Qlty Smell Threshold")
    and ((.app.slug // "") == "github-actions")
    and ((.workflow_path // "") == ".github/workflows/code-quality.yml")
    and ((.workflow_event // "") == "push") then
    "baseline-ratchet-covered-by-pr-regression-gate"
  elif ((.name // "") == "SonarCloud Code Analysis")
    and ((.app.slug // "") == "sonarcloud") then
    "external-analysis"
  else
    null
  end;

def required_check($reason):
  . + {
    classification: "required",
    classification_reason: $reason
  };

def advisory_check($reason):
  . + {
    classification: "advisory",
    classification_reason: $reason
  };

def workflow_runs($documents):
  (($documents
    | flatten
    | map(.workflow_runs // [])
    | add) // []);

def with_workflow_provenance($workflow_runs):
  . as $check
  | ($check.check_suite.id // null) as $suite_id
  | (if $suite_id == null then null
     else (
       $workflow_runs
       | map(select(.check_suite_id == $suite_id))
       | max_by([run_id, (.run_attempt // 0), run_time])
     )
     end) as $workflow
  | if $workflow == null then .
    else . + {
      workflow_path: ($workflow.path // null),
      workflow_event: ($workflow.event // null),
      workflow_run_id: ($workflow.id // null),
      workflow_run_attempt: ($workflow.run_attempt // null)
    }
    end;

def valid_release_tag:
  $release_tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$");

def correlated_primary_publication_run:
  (.head_branch // "") as $primary_tag
  | valid_release_tag
  and ($primary_tag == $release_tag)
  and (.event == "push")
  and (.path == ".github/workflows/publish-packages.yml")
  and (.head_sha == $release_sha)
  and ((.id // null) | type == "number")
  and (
    (.name // "")
    == ("Publish " + $primary_tag + " [" + $release_sha + "." + $release_sha + "]")
  );

def correlated_recovery_run:
  valid_release_tag
  and (.event == "workflow_dispatch")
  and (.path == ".github/workflows/publish-packages.yml")
  and (.head_branch == "main")
  and ((.head_sha // "") | test("^[0-9a-f]{40}$"))
  and ((.id // null) | type == "number")
  and ((.check_suite_id // null) | type == "number")
  and (
    (.name // "")
    == ("Publish " + $release_tag + " [" + $release_sha + "." + (.head_sha // "") + "]")
  );

def publication_check:
  {
    id,
    name: "Publish GitHub, npm, and Homebrew",
    status,
    conclusion,
    completed_at: (
      if .status == "completed"
      then (.updated_at // .run_started_at // .created_at)
      else null
      end
    ),
    started_at: .run_started_at,
    created_at,
    updated_at,
    check_suite: {id: .check_suite_id},
    app: {slug: "github-actions"},
    classification: "required",
    classification_reason: "release-publication"
  };

def primary_publication_check:
  publication_check
  + {publication_workflow_run_id: .id};

def recovery_check:
  publication_check
  + {recovery_workflow_run_id: .id};

def missing_publication_check:
  {
    id: null,
    name: "Publish GitHub, npm, and Homebrew",
    status: "missing",
    conclusion: null,
    completed_at: null,
    started_at: null,
    created_at: null,
    updated_at: null,
    check_suite: {id: null},
    app: {slug: "github-actions"},
    classification: "required",
    classification_reason: "release-publication-missing"
  };

def release_workflow_check:
  {
    id,
    name: ("Workflow " + (.path // .name // "unknown")),
    status: (.status // "missing"),
    conclusion,
    completed_at: (
      if .status == "completed"
      then (.updated_at // .run_started_at // .created_at)
      else null
      end
    ),
    started_at: .run_started_at,
    created_at,
    updated_at,
    check_suite: {id: .check_suite_id},
    app: {slug: "github-actions"},
    workflow_run_id: .id,
    workflow_run_attempt: (.run_attempt // null),
    workflow_path: (.path // null),
    workflow_event: (.event // null),
    classification: "required",
    classification_reason: "release-owned-workflow"
  };

def accepted_terminal_conclusion:
  . as $conclusion
  | (["success", "neutral", "skipped"] | index($conclusion)) != null;

def accepted_terminal_evidence:
  (.status == "completed")
  and ((.conclusion // "") | accepted_terminal_conclusion);

def suite_has_required_blocking_evidence($suite_checks):
  $suite_checks
  | any(
      (postflight_advisory_reason == null)
      and ((accepted_terminal_evidence) | not)
    );

def suite_failure_is_advisory_only($suite_checks):
  ($suite_checks
   | any(
       (postflight_advisory_reason != null)
       and ((accepted_terminal_evidence) | not)
     ))
  and ($suite_checks
       | all(
           if postflight_advisory_reason == null
           then accepted_terminal_evidence
           else .status == "completed"
           end
         ));

def workflow_needs_direct_evidence($suite_checks):
  if (($suite_checks | length) == 0) or (.status != "completed") then true
  elif ((.conclusion // "") | accepted_terminal_conclusion) then false
  elif (.conclusion == "failure") and suite_failure_is_advisory_only($suite_checks) then false
  elif suite_has_required_blocking_evidence($suite_checks) then false
  else true
  end;

(workflow_runs($release_run_documents)) as $release_workflow_runs
|
((.check_runs // []) | map(with_workflow_provenance($release_workflow_runs))) as $all_check_runs
|
($all_check_runs | latest_by_key) as $effective_check_runs
|
(workflow_runs($release_run_documents)
 | map(select(correlated_primary_publication_run))) as $correlated_primary_publication_runs
|
(workflow_runs($recovery_run_documents)
 | map(select(correlated_recovery_run))) as $correlated_recovery_runs
|
(($correlated_primary_publication_runs | map(primary_publication_check))
 + ($correlated_recovery_runs | map(recovery_check))) as $publication_checks
|
(if ($publication_checks | length) == 0
 then [missing_publication_check]
 else $publication_checks
 end) as $required_publication_checks
|
($release_workflow_runs
 | map(
     select(.head_sha == $release_sha)
     | select(.event == "push" or .event == "release" or .event == "workflow_dispatch")
     | select(.path != ".github/workflows/publish-packages.yml")
     | select(.path != ".github/workflows/postflight.yml")
   )) as $release_owned_workflow_runs
|
($release_owned_workflow_runs
 | map(
     . as $workflow
     | ($effective_check_runs
        | map(
            select(.name != $self_name)
            | select(.check_suite.id == $workflow.check_suite_id)
          )) as $suite_checks
     | select($workflow | workflow_needs_direct_evidence($suite_checks))
     | $workflow
     | release_workflow_check
   )) as $workflow_checks
|
($release_workflow_runs
 | map(
     select(.head_sha == $release_sha)
     | select(.event == "push" or .event == "release" or .event == "workflow_dispatch")
     | .check_suite_id
   )
 | map(select(. != null))
 | unique) as $release_suite_ids
|
($release_workflow_runs
 | map(
     select(.head_sha == $release_sha)
     | select((.event == "push" or .event == "release" or .event == "workflow_dispatch") | not)
     | {id, name, event, status, conclusion, check_suite_id}
   )
 | sort_by([(.created_at // .run_started_at // ""), (.id // 0)])
) as $unrelated_workflow_runs
|
{
  check_runs: (
    (
      [
        $effective_check_runs[]?
        | select(.name != $self_name)
        | select(.name != "Publish GitHub, npm, and Homebrew")
        | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id))
        | select(postflight_advisory_reason == null)
        | required_check("release-owned-check")
      ]
      + $required_publication_checks
      + $workflow_checks
    )
    | latest_by_key
  ),
  advisory_check_runs: (
    [
      (
        $effective_check_runs[]?
        | select(.name != $self_name)
        | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id))
        | postflight_advisory_reason as $reason
        | select($reason != null)
        | advisory_check($reason)
      ),
      (
        $effective_check_runs[]?
        | select(.name != $self_name)
        | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id) | not)
        | select((.app.slug // "") != "github-actions")
        | advisory_check("external-provider")
      )
    ]
    | latest_by_key
  ),
  unrelated_workflow_runs: $unrelated_workflow_runs,
  recovery_workflow_runs: (
    $correlated_recovery_runs
    | map({id, name, event, head_sha, status, conclusion, check_suite_id})
  )
}
