def trusted_association:
    . == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";

def field($body; $name):
    ((try ($body | capture("(^|[[:space:]])" + $name + "=(?<value>[^[:space:]]+)").value) catch "") // "");

def author_login:
    .author // .user.login // "";

def comment_order:
    [(.created_at | fromdateiso8601? // 0), (.id | tonumber? // 0)];

input as $claims |
input as $comments |
($claims
 | map(. as $comment
       | ($comment.body // "") as $body
       | select($body | test("(^|[[:space:]])DISPATCH_CLAIM[[:space:]]+nonce="; "i"))
       | (field($body; "nonce")) as $nonce
       | (field($body; "runner")) as $runner
       | (field($body; "ts")) as $ts
       | (field($body; "version")) as $version
       | (field($body; "lease_token")) as $lease_token
       | (field($body; "device")) as $device
       | (field($body; "session")) as $session
       | (field($body; "expires_at")) as $expires
       | {
           id: $comment.id,
           nonce: $nonce,
           runner: $runner,
           ts: $ts,
           version: (if $version == "" then "unknown" else $version end),
           lease_token: $lease_token,
           device: (if $device == "" then "legacy" else $device end),
           session: $session,
            claim_author: ($comment | author_login),
            claim_association: ($comment.author_association // ""),
           lease_expires_at: ($expires | tonumber? // 0),
           created_at: ($comment.created_at // ""),
           created_epoch: ($comment.created_at | fromdateiso8601? // 0)
         }
       #aidevops:trust-boundary
       | select(.nonce != "" and .runner != "" and .ts != "")
       | select(.claim_author != "" and .claim_author == .runner)
       | select(.claim_association | trusted_association)
   )) as $parsed_claims |
[$parsed_claims[]
 | . as $claim
 | ([ $comments[]
      | . as $comment
      | ($comment.body // "") as $body
      | select($body | test("(^|[[:space:]])DISPATCH_LEASE[[:space:]]+phase="; "i"))
      | (field($body; "phase")) as $phase
      | (field($body; "lease_token")) as $lease_token
      | (field($body; "device")) as $device
      | (field($body; "session")) as $session
      | (field($body; "expires_at")) as $expires
      | (field($body; "attempt_id")) as $attempt_id
      #aidevops:trust-boundary
      | select(($comment.author_association // "") | trusted_association)
      | select(($comment | author_login) != "" and ($comment | author_login) == $claim.claim_author)
      | select($lease_token != "" and $lease_token == $claim.lease_token and $device == $claim.device and $session == $claim.session)
      | select($phase == "prelaunch" or $phase == "ready" or $phase == "terminal")
      | select($comment | comment_order > [$claim.created_epoch, ($claim.id | tonumber? // 0)])
      | {phase:$phase, expires:($expires | tonumber? // 0), at:($comment.created_at // ""),
         epoch:($comment.created_at | fromdateiso8601? // 0), id:($comment.id | tonumber? // 0),
         attempt_id:(if $attempt_id == "" then "unknown" else $attempt_id end)}
    ]
    + [ $comments[]
        | . as $comment
        | ($comment.body // "") as $body
        | select($body | test("(^|[[:space:]])CLAIM_RELEASED([[:space:]]|$)"; "i"))
        | (field($body; "claim_id")) as $claim_id
        | (field($body; "nonce")) as $nonce
        | (field($body; "runner")) as $runner
        #aidevops:trust-boundary
        | select(($comment.author_association // "") | trusted_association)
        | select(($comment | author_login) != "" and ($comment | author_login) == $claim.claim_author)
        | select($claim_id != "" and $nonce != "" and $runner != "")
        | select($runner == $claim.runner)
        | select($claim_id == ($claim.id | tostring) and $nonce == $claim.nonce)
        | select($comment | comment_order > [$claim.created_epoch, ($claim.id | tonumber? // 0)])
        | {phase:"terminal", expires:0, at:($comment.created_at // ""),
           epoch:($comment.created_at | fromdateiso8601? // 0), id:($comment.id | tonumber? // 0),
           attempt_id:"release"}
      ]
    | sort_by([.epoch, .id])) as $events
  | (reduce $events[] as $event
       ({phase:"prelaunch", expires:$claim.lease_expires_at, terminal_at:"", terminal_id:0, terminal_attempt_id:""};
        if .phase == "terminal" or (.expires > 0 and .expires < $event.epoch) then .
       elif $event.phase == "prelaunch" and .phase == "prelaunch" and $event.expires >= $event.epoch
         then .phase="prelaunch" | .expires=$event.expires
       elif $event.phase == "ready" and .phase == "prelaunch" and $event.expires >= $event.epoch
         then .phase="ready" | .expires=$event.expires
       elif $event.phase == "terminal" and (.phase == "prelaunch" or .phase == "ready")
         then .phase="terminal" | .expires=0 | .terminal_at=$event.at | .terminal_id=$event.id | .terminal_attempt_id=$event.attempt_id
       else . end)) as $state
 | $claim + {age_seconds: ($now - $claim.created_epoch), lease_phase:$state.phase,
             lease_expires_at:$state.expires, lease_terminal_at:$state.terminal_at,
             lease_terminal_id:$state.terminal_id, lease_terminal_attempt_id:$state.terminal_attempt_id}
] |
map(select(.age_seconds >= 0 and (.age_seconds <= $max_age or (.lease_phase == "ready" and .lease_expires_at >= $now)))) |
(if $include_terminal then . else
    map(select(.lease_phase != "terminal" and ((.lease_expires_at // 0) == 0 or .lease_expires_at >= $now)))
 end) |
sort_by([.created_at, .nonce])
