def reconciliation_key:
  [
    (.name // ""),
    (.app.slug // .app.name // ""),
    (.workflow_path // ""),
    (.workflow_event // "")
  ];

def has_workflow_provenance:
  ((.workflow_path // "") != "") and ((.workflow_event // "") != "");

def current_runs: $current_run_documents[0] // [];

def descendant_runs: $descendant_run_documents[0] // [];

def can_reconcile:
  (.conclusion == "cancelled")
  and has_workflow_provenance
  and (((.classification_reason // "") | startswith("release-publication")) | not);

def successful_descendant($key):
  [
    descendant_runs[]
    | select(has_workflow_provenance)
    | select(reconciliation_key == $key)
    | select(.status == "completed" and .conclusion == "success")
  ]
  | last // null;

[
  current_runs[]
  | if can_reconcile then
      reconciliation_key as $key
      | successful_descendant($key) as $replacement
      | if $replacement == null then .
        else .
          | .status = "completed"
          | .conclusion = "success"
          | .superseded_by_check_run_id = ($replacement.id // null)
        end
    else .
    end
]
