# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-aggregate.awk -- Aggregate logical gh events and transport attempts
# =============================================================================
# Reads legacy three/seven-column records and versioned v2 records emitted by
# gh-api-instrument.sh. Legacy rows remain logical observations; they are never
# represented as proven network attempts. Designed for BSD awk (macOS default).
#
# Required -v variables: now (inclusive fixed-window end), cutoff, window
# Output: one deterministic JSON document on stdout.
# =============================================================================

BEGIN {
	total_calls = 0
	logical_events = 0
	cache_events = 0
	evidence_events = 0
	timeout_events = 0
	timeout_elapsed_ms = 0
	unknown_timeout_elapsed_events = 0
	legacy_events = 0
	attempted_requests = 0
	opaque_paginated_attempts = 0
}

function metric_add(group, value, metric, amount,    key) {
	if (value == "") value = "unknown"
	key = group SUBSEP value
	group_keys[key] = 1
	metrics[key SUBSEP metric] += amount
}

function metric_get(group, value, metric) {
	return metrics[group SUBSEP value SUBSEP metric] + 0
}

function metric_add_dimensions(caller, path, auth, pool, decision, metric, amount) {
	metric_add("caller", caller, metric, amount)
	metric_add("path", path, metric, amount)
	metric_add("auth", auth, metric, amount)
	metric_add("pool", pool, metric, amount)
	metric_add("decision", decision, metric, amount)
}

function percentile(histogram, total, percent,    target, cumulative, key, values, n, i) {
	if (total < 1) return 0
	for (key in histogram) values[++n] = key + 0
	sort_values(values, n)
	target = int((total * percent + 99) / 100)
	for (i = 1; i <= n; i++) {
		cumulative += histogram[values[i]]
		if (cumulative >= target) return values[i]
	}
	return values[n] + 0
}

function sort_values(values, n,    i, j, swap) {
	for (i = 2; i <= n; i++) {
		for (j = i; j > 1 && values[j - 1] > values[j]; j--) {
			swap = values[j]
			values[j] = values[j - 1]
			values[j - 1] = swap
		}
	}
}

function emit_group(title, group,    pair, parts, values, n, i, value) {
	printf "  \"%s\": {\n", title
	n = 0
	for (pair in group_keys) {
		split(pair, parts, SUBSEP)
		if (parts[1] == group) values[++n] = parts[2]
	}
	sort_values(values, n)
	for (i = 1; i <= n; i++) {
		value = values[i]
		if (i > 1) print ","
		printf "    \"%s\": {\n", value
		printf "      \"graphql_calls\": %d,\n", metric_get(group, value, "graphql_calls")
		printf "      \"rest_calls\": %d,\n", metric_get(group, value, "rest_calls")
		printf "      \"search_graphql_calls\": %d,\n", metric_get(group, value, "search_graphql_calls")
		printf "      \"search_rest_calls\": %d,\n", metric_get(group, value, "search_rest_calls")
		printf "      \"other_calls\": %d,\n", metric_get(group, value, "other_calls")
		printf "      \"total\": %d,\n", metric_get(group, value, "total")
		printf "      \"logical_events\": %d,\n", metric_get(group, value, "logical_events")
		printf "      \"cache_events\": %d,\n", metric_get(group, value, "cache_events")
		printf "      \"evidence_events\": %d,\n", metric_get(group, value, "evidence_events")
		printf "      \"timeout_events\": %d,\n", metric_get(group, value, "timeout_events")
		printf "      \"timeout_elapsed_ms\": %d,\n", metric_get(group, value, "timeout_elapsed_ms")
		printf "      \"unknown_timeout_elapsed_events\": %d,\n", metric_get(group, value, "unknown_timeout_elapsed_events")
		printf "      \"legacy_events\": %d,\n", metric_get(group, value, "legacy_events")
		printf "      \"attempted_requests\": %d,\n", metric_get(group, value, "attempted_requests")
		printf "      \"opaque_paginated_attempts\": %d,\n", metric_get(group, value, "opaque_paginated_attempts")
		printf "      \"retries\": %d,\n", metric_get(group, value, "retries")
		printf "      \"pages\": %d,\n", metric_get(group, value, "pages")
		printf "      \"additional_pages\": %d,\n", metric_get(group, value, "additional_pages")
		printf "      \"successful_attempts\": %d,\n", metric_get(group, value, "successful_attempts")
		printf "      \"failed_attempts\": %d,\n", metric_get(group, value, "failed_attempts")
		printf "      \"elapsed_ms\": %d,\n", metric_get(group, value, "elapsed_ms")
		printf "      \"unknown_elapsed_attempts\": %d,\n", metric_get(group, value, "unknown_elapsed_attempts")
		printf "      \"known_quota_cost\": %d,\n", metric_get(group, value, "known_quota_cost")
		printf "      \"unknown_quota_cost_attempts\": %d\n", metric_get(group, value, "unknown_quota_cost_attempts")
		printf "    }"
	}
	if (n > 0) print ""
	print "  }"
}

function record_budget(pool, budget, ts) {
	if (budget !~ /^[0-9]+$/) return
	budget_keys[pool] = 1
	if (!(pool in budget_min) || budget + 0 < budget_min[pool] + 0) budget_min[pool] = budget
	if (!(pool in budget_last_ts) || ts >= budget_last_ts[pool]) {
		budget_last_ts[pool] = ts
		budget_last[pool] = budget
	}
}

function emit_budgets(    pool, values, n, i) {
	print "  \"budget_by_pool\": {"
	n = 0
	for (pool in budget_keys) values[++n] = pool
	sort_values(values, n)
	for (i = 1; i <= n; i++) {
		pool = values[i]
		if (i > 1) print ","
		printf "    \"%s\": {\"min_remaining\": %d, \"last_remaining\": %d}", pool, budget_min[pool] + 0, budget_last[pool] + 0
	}
	if (n > 0) print ""
	print "  }"
}

# Reject records without a numeric timestamp or the legacy prefix.
$1 !~ /^[0-9]+$/ || NF < 3 {
	malformed_records++
	next
}

{
	ts = $1 + 0
	if (ts > now) next
	caller = ($2 != "") ? $2 : "unknown"
	path = ($3 != "") ? $3 : "other"
	auth = (NF >= 4 && $4 != "") ? $4 : "unknown"
	pool = (NF >= 5 && $5 != "") ? $5 : path
	decision = (NF >= 6 && $6 != "") ? $6 : "unspecified"
	budget = (NF >= 7) ? $7 : ""
	version = (NF >= 8) ? $8 : ""
	attempt_unidentified = 0
	attempt_duplicate = 0
	attempt_page_unknown = 0

	if (version == "v2" && NF < 17) {
		malformed_records++
		malformed_v2_records++
		if (ts >= cutoff) window_malformed_v2_records++
		next
	}

	if (version == "v2") {
		kind = ($9 != "") ? $9 : "logical"
		logical_id = $10
		attempt_id = $11
		page = $12
		retry = $13
		outcome = ($14 != "") ? $14 : "unknown"
		http_status = $15
		elapsed_ms = $16
		quota_cost = $17
	} else {
		kind = "legacy"
		logical_id = ""
		attempt_id = ""
		page = ""
		retry = ""
		outcome = "unknown"
		http_status = ""
		elapsed_ms = ""
		quota_cost = ""
		retained_legacy_records++
	}

	retained_records++
	if (first_retained_record_ts == 0 || ts < first_retained_record_ts) first_retained_record_ts = ts
	if (ts > last_retained_record_ts) last_retained_record_ts = ts

	if (kind == "attempt") {
		if (attempt_id == "" || attempt_id == "unknown") {
			retained_unidentified_attempts++
			attempt_unidentified = 1
		} else if (attempt_id in seen_retained_attempt_id) {
			retained_duplicate_attempt_ids++
		} else {
			seen_retained_attempt_id[attempt_id] = 1
		}
		if (page !~ /^[0-9]+$/ || page + 0 < 1) {
			retained_unknown_page_attempts++
			attempt_page_unknown = 1
		}
		if (first_observed_attempt_ts == 0 || ts < first_observed_attempt_ts) first_observed_attempt_ts = ts
		if (ts > last_observed_attempt_ts) last_observed_attempt_ts = ts
	}

	if (ts < cutoff) next
	window_records++
	if (kind == "attempt" && !attempt_unidentified) {
		if (attempt_id in seen_window_attempt_id) {
			attempt_duplicate = 1
		} else {
			seen_window_attempt_id[attempt_id] = 1
		}
	}
	record_budget(pool, budget, ts)
	if (logical_id != "" && logical_id != "unknown" && !(logical_id in seen_window_logical_id)) {
		seen_window_logical_id[logical_id] = 1
		logical_operations++
	}

	if (kind == "evidence") {
		evidence_events++
		metric_add_dimensions(caller, path, auth, pool, decision, "evidence_events", 1)
		next
	}
	if (kind == "timeout") {
		timeout_events++
		metric_add_dimensions(caller, path, auth, pool, decision, "timeout_events", 1)
		metric_add("outcome", outcome, "timeout_events", 1)
		if (elapsed_ms ~ /^[0-9]+$/) {
			timeout_elapsed_ms += elapsed_ms
			metric_add_dimensions(caller, path, auth, pool, decision, "timeout_elapsed_ms", elapsed_ms)
		} else {
			unknown_timeout_elapsed_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "unknown_timeout_elapsed_events", 1)
		}
		next
	}

	if (kind != "attempt") {
		total_calls++
		metric_add_dimensions(caller, path, auth, pool, decision, "total", 1)
		if (path == "graphql") call_metric = "graphql_calls"
		else if (path == "rest") call_metric = "rest_calls"
		else if (path == "search-graphql") call_metric = "search_graphql_calls"
		else if (path == "search-rest") call_metric = "search_rest_calls"
		else call_metric = "other_calls"
		metric_add_dimensions(caller, path, auth, pool, decision, call_metric, 1)
		if (kind == "cache") {
			cache_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "cache_events", 1)
		} else if (kind == "legacy") {
			legacy_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "legacy_events", 1)
		} else {
			logical_events++
			metric_add_dimensions(caller, path, auth, pool, decision, "logical_events", 1)
		}
		next
	}
	if (attempt_unidentified) unidentified_attempts++
	if (attempt_duplicate) {
		duplicate_attempt_ids++
		next
	}
	if (first_window_attempt_ts == 0 || ts < first_window_attempt_ts) first_window_attempt_ts = ts
	if (ts > last_window_attempt_ts) last_window_attempt_ts = ts
	if (attempt_page_unknown) unknown_page_attempts++

	attempted_requests++
	minute = int(ts / 60)
	minute_attempts[minute]++
	if (minute_attempts[minute] > peak_attempts_per_minute) {
		peak_attempts_per_minute = minute_attempts[minute]
	}
	metric_add_dimensions(caller, path, auth, pool, decision, "attempted_requests", 1)
	metric_add("outcome", outcome, "attempted_requests", 1)
	if (decision == "native-pagination-opaque") {
		opaque_paginated_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "opaque_paginated_attempts", 1)
	}
	if (retry ~ /^[0-9]+$/ && retry + 0 > 0) {
		retries++
		metric_add_dimensions(caller, path, auth, pool, decision, "retries", 1)
		metric_add("outcome", outcome, "retries", 1)
	}
	if (page ~ /^[0-9]+$/ && page + 0 > 0) {
		pages++
		metric_add_dimensions(caller, path, auth, pool, decision, "pages", 1)
		if (page + 0 > 1) {
			additional_pages++
			metric_add_dimensions(caller, path, auth, pool, decision, "additional_pages", 1)
		}
	}
	if (outcome == "success") {
		successful_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "successful_attempts", 1)
	} else {
		failed_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "failed_attempts", 1)
	}
	if (elapsed_ms ~ /^[0-9]+$/) {
		elapsed_value = elapsed_ms + 0
		elapsed_ms_total += elapsed_value
		latency_hist[elapsed_value]++
		latency_count++
		metric_add_dimensions(caller, path, auth, pool, decision, "elapsed_ms", elapsed_ms)
	} else {
		unknown_elapsed_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "unknown_elapsed_attempts", 1)
	}
	if (quota_cost ~ /^[0-9]+$/) {
		known_quota_cost += quota_cost
		metric_add_dimensions(caller, path, auth, pool, decision, "known_quota_cost", quota_cost)
	} else {
		unknown_quota_cost_attempts++
		metric_add_dimensions(caller, path, auth, pool, decision, "unknown_quota_cost_attempts", 1)
	}
	if (http_status ~ /^[0-9]+$/) metric_add("http_status", http_status, "attempted_requests", 1)
}

END {
	effective_window_seconds = 0
	if (first_window_attempt_ts > 0 && last_window_attempt_ts >= first_window_attempt_ts) {
		effective_window_seconds = last_window_attempt_ts - first_window_attempt_ts
	}
	request_p50_ms = percentile(latency_hist, latency_count, 50)
	request_p95_ms = percentile(latency_hist, latency_count, 95)
	attempts_exact = (duplicate_attempt_ids == 0 && unidentified_attempts == 0 && unknown_page_attempts == 0 && window_malformed_v2_records == 0) ? "true" : "false"

	print "{"
	print "  \"_meta\": {"
	print "    \"schema_version\": 2,"
	printf "    \"generated_at_ts\": %d,\n", now
	printf "    \"since_ts\": %d,\n", cutoff
	printf "    \"requested_window_seconds\": %d,\n", window
	printf "    \"window_seconds\": %d,\n", window
	printf "    \"first_retained_ts\": %d,\n", first_window_attempt_ts + 0
	printf "    \"last_retained_ts\": %d,\n", last_window_attempt_ts + 0
	printf "    \"effective_window_seconds\": %d,\n", effective_window_seconds
	printf "    \"first_observed_attempt_ts\": %d,\n", first_observed_attempt_ts + 0
	printf "    \"last_observed_attempt_ts\": %d,\n", last_observed_attempt_ts + 0
	printf "    \"first_retained_record_ts\": %d,\n", first_retained_record_ts + 0
	printf "    \"last_retained_record_ts\": %d,\n", last_retained_record_ts + 0
	printf "    \"retained_records\": %d,\n", retained_records + 0
	printf "    \"window_records\": %d,\n", window_records + 0
	printf "    \"total_calls\": %d,\n", total_calls
	printf "    \"logical_operations\": %d,\n", logical_operations + 0
	printf "    \"logical_events\": %d,\n", logical_events
	printf "    \"cache_events\": %d,\n", cache_events
	printf "    \"evidence_events\": %d,\n", evidence_events
	printf "    \"timeout_events\": %d,\n", timeout_events
	printf "    \"timeout_elapsed_ms\": %d,\n", timeout_elapsed_ms
	printf "    \"unknown_timeout_elapsed_events\": %d,\n", unknown_timeout_elapsed_events
	printf "    \"legacy_events\": %d,\n", legacy_events
	printf "    \"attempted_requests\": %d,\n", attempted_requests
	printf "    \"opaque_paginated_attempts\": %d,\n", opaque_paginated_attempts + 0
	printf "    \"retries\": %d,\n", retries + 0
	printf "    \"pages\": %d,\n", pages + 0
	printf "    \"additional_pages\": %d,\n", additional_pages + 0
	printf "    \"successful_attempts\": %d,\n", successful_attempts + 0
	printf "    \"failed_attempts\": %d,\n", failed_attempts + 0
	printf "    \"elapsed_ms\": %d,\n", elapsed_ms_total + 0
	printf "    \"unknown_elapsed_attempts\": %d,\n", unknown_elapsed_attempts + 0
	printf "    \"request_p50_ms\": %d,\n", request_p50_ms + 0
	printf "    \"request_p95_ms\": %d,\n", request_p95_ms + 0
	printf "    \"peak_attempts_per_minute\": %d,\n", peak_attempts_per_minute + 0
	printf "    \"known_quota_cost\": %d,\n", known_quota_cost + 0
	printf "    \"unknown_quota_cost_attempts\": %d,\n", unknown_quota_cost_attempts + 0
	printf "    \"duplicate_attempt_ids\": %d,\n", duplicate_attempt_ids + 0
	printf "    \"unidentified_attempts\": %d,\n", unidentified_attempts + 0
	printf "    \"unknown_page_attempts\": %d,\n", unknown_page_attempts + 0
	printf "    \"retained_duplicate_attempt_ids\": %d,\n", retained_duplicate_attempt_ids + 0
	printf "    \"retained_unidentified_attempts\": %d,\n", retained_unidentified_attempts + 0
	printf "    \"retained_unknown_page_attempts\": %d,\n", retained_unknown_page_attempts + 0
	printf "    \"window_malformed_v2_records\": %d,\n", window_malformed_v2_records + 0
	printf "    \"legacy_retained_records\": %d,\n", retained_legacy_records + 0
	printf "    \"malformed_records\": %d,\n", malformed_records + 0
	printf "    \"attempts_exact\": %s\n", attempts_exact
	print "  },"
	emit_group("by_caller", "caller")
	print ","
	emit_group("by_path", "path")
	print ","
	emit_group("by_auth_mode", "auth")
	print ","
	emit_group("by_api_pool", "pool")
	print ","
	emit_group("by_route_decision", "decision")
	print ","
	emit_group("by_outcome", "outcome")
	print ","
	emit_group("attempts_by_http_status", "http_status")
	print ","
	emit_budgets()
	print "}"
}
