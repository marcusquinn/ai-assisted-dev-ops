input as $claims |
input as $comments |
[$claims[] |
    (.body | capture("nonce=(?<nonce>[^ ]+) runner=(?<runner>[^ ]+) ts=(?<ts>[^ ]+)(?: max_age_s=[^ ]+)?(?: version=(?<version>[^ ]+))?")) as $fields |
    ((.body | try capture("lease_token=(?<value>[^ ]+)").value catch "") // "") as $token |
    ((.body | try capture("device=(?<value>[^ ]+)").value catch "") // "") as $device |
    ((.body | try capture("session=(?<value>[^ ]+)").value catch "") // "") as $session |
    ((.body | try capture("expires_at=(?<value>[0-9]+)").value catch "0") // "0") as $expires |
    {
        id: .id, nonce: $fields.nonce, runner: $fields.runner, ts: $fields.ts,
        version: ($fields.version // "unknown"),
        lease_token: (if $token == "" then $fields.nonce else $token end),
        device: (if $device == "" then "legacy" else $device end),
        session: $session,
        claim_author: (.author // .user.login // ""),
        lease_expires_at: ($expires | tonumber? // 0),
        created_at: .created_at,
        created_epoch: (.created_at | fromdateiso8601? // 0)
    }
] |
map(. + {age_seconds: ($now - .created_epoch)}) |
map(. as $claim |
    ([ $comments[]
       | select((.body // "") | contains("lease_token=" + $claim.lease_token))
       | select((.body // "") | contains("DISPATCH_LEASE"))
       | select(($claim.claim_author != "") and ((.author // .user.login // "") == $claim.claim_author))
       | . + ((.body | capture("phase=(?<phase>[^ ]+) lease_token=[^ ]+ device=(?<device>[^ ]+) session=(?<session>[^ ]+) expires_at=(?<expires>[0-9]+)")) as $t
               | {transition_phase:$t.phase, transition_device:$t.device, transition_session:$t.session,
                  transition_expires:($t.expires|tonumber), transition_epoch:(.created_at | fromdateiso8601? // 0),
                  transition_at:(.created_at // ""), transition_id:(.id | tonumber? // 0)})
       | select(.transition_device == $claim.device and .transition_session == $claim.session)
       | select([.transition_epoch, .transition_id] >= [$claim.created_epoch, ($claim.id | tonumber? // 0)])
      ] | sort_by(.created_at, .id)) as $transitions |
    (reduce $transitions[] as $event
      ({phase:"prelaunch", expires:$claim.lease_expires_at, terminal_at:"", terminal_id:0};
       if .phase == "terminal" or .expires < $event.transition_epoch then .
       elif $event.transition_phase == "prelaunch" and .phase == "prelaunch" and $event.transition_expires >= $event.transition_epoch
         then .phase="prelaunch" | .expires=$event.transition_expires
       elif $event.transition_phase == "ready" and .phase == "prelaunch" and $event.transition_expires >= $event.transition_epoch
         then .phase="ready" | .expires=$event.transition_expires
       elif $event.transition_phase == "terminal" and (.phase == "prelaunch" or .phase == "ready")
         then .phase="terminal" | .expires=0 | .terminal_at=$event.transition_at | .terminal_id=$event.transition_id
       else . end)) as $state |
    $claim + {lease_phase:$state.phase, lease_expires_at:$state.expires,
              lease_terminal_at:$state.terminal_at, lease_terminal_id:$state.terminal_id}) |
map(select(.age_seconds >= 0 and (.age_seconds <= $max_age or (.lease_phase == "ready" and .lease_expires_at >= $now)))) |
(if $include_terminal then . else
    map(select(.lease_phase != "terminal" and ((.lease_expires_at // 0) == 0 or .lease_expires_at >= $now)))
 end) |
sort_by([.created_at, .nonce])
