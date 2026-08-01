def run_key:
  [(.name // ""), (.app.slug // .app.name // ""), (.workflow_run_id // "")];

def run_time:
  .created_at // .started_at // .updated_at // .completed_at // "";

def run_id:
  if (.id | type) == "number" then .id else 0 end;

def workflow_runs:
  (($workflow_run_documents
    | flatten
    | map(.workflow_runs // [])
    | add) // []);

def with_workflow_provenance:
  . as $check
  | ($check.check_suite.id // null) as $suite_id
  | (if $suite_id == null then null
     else (
       workflow_runs
       | map(select(.check_suite_id == $suite_id))
       | max_by([(.id // 0), (.run_attempt // 0), (.created_at // .updated_at // "")])
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

[
  .check_runs[]
  | select(.name != $self_name)
  | with_workflow_provenance
]
| sort_by(run_key)
| group_by(run_key)
| map(max_by([run_id, run_time]))
