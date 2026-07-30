def run_key: [(.name // ""), (.app.slug // .app.name // "")];

def run_time:
  .completed_at // .started_at // .created_at // .updated_at // "";

def latest_by_key:
  sort_by(run_key)
  | group_by(run_key)
  | map(max_by([run_time, (.id // 0)]));

def workflow_runs($documents):
  (($documents
    | flatten
    | map(.workflow_runs // [])
    | add) // []);

def correlated_recovery_run:
  ($release_tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
  and (.event == "workflow_dispatch")
  and (.path == ".github/workflows/publish-packages.yml")
  and ((.head_sha // "") | test("^[0-9a-f]{40}$"))
  and ((.id // null) | type == "number")
  and ((.check_suite_id // null) | type == "number")
  and (
    (.name // "")
    == ("Publish " + $release_tag + " [" + $release_sha + "." + (.head_sha // "") + "]")
  );

def recovery_check:
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
    recovery_workflow_run_id: .id
  };

(workflow_runs($release_run_documents)) as $release_workflow_runs
|
(workflow_runs($recovery_run_documents)
 | map(select(correlated_recovery_run))) as $correlated_recovery_runs
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
        .check_runs[]?
        | select(.name != $self_name)
        | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id))
      ]
      + ($correlated_recovery_runs | map(recovery_check))
    )
    | latest_by_key
  ),
  advisory_check_runs: (
    [
      .check_runs[]?
      | select(.name != $self_name)
      | select(.check_suite.id as $suite_id | $release_suite_ids | index($suite_id) | not)
      | select((.app.slug // "") != "github-actions")
    ]
    | latest_by_key
  ),
  unrelated_workflow_runs: $unrelated_workflow_runs,
  recovery_workflow_runs: (
    $correlated_recovery_runs
    | map({id, name, event, head_sha, status, conclusion, check_suite_id})
  )
}
