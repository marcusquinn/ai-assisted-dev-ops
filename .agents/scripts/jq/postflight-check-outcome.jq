def accepted_conclusion:
  . == "success" or . == "neutral" or . == "skipped";

def accepted_run:
  if .classification_reason == "release-publication" then
    .conclusion == "success"
  else
    (.conclusion // "") | accepted_conclusion
  end;

def classify_runs($runs):
  ($runs // []) as $all
  | {
      all: $all,
      total: ($all | length),
      pending: [
        $all[]
        | select(.status != "completed")
      ],
      accepted: [
        $all[]
        | select(.status == "completed")
        | select(accepted_run)
      ],
      failed: [
        $all[]
        | select(.status == "completed")
        | select((accepted_run) | not)
      ]
    };

{
  required: classify_runs(.check_runs),
  advisory: classify_runs(.advisory_check_runs)
}
