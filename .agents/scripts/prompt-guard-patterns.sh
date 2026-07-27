#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Prompt Guard Patterns -- Pattern loading and inline fallback definitions
# =============================================================================
# Loads patterns from prompt-injection-patterns.yaml (primary) with
# inline _pg_get_patterns() as fallback when YAML is unavailable.
# YAML format is Lasso-compatible for upstream pattern sharing.
#
# Usage: source "${SCRIPT_DIR}/prompt-guard-patterns.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - _pg_log_info, _pg_log_warn from prompt-guard-helper.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROMPT_GUARD_PATTERNS_LIB_LOADED:-}" ]] && return 0
_PROMPT_GUARD_PATTERNS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Cache for loaded YAML patterns (populated on first use)
_PG_YAML_PATTERNS_CACHE=""
_PG_YAML_PATTERNS_LOADED="false"

# ============================================================
# YAML PATTERN LOADING (t1375.1)
# ============================================================
# Loads patterns from prompt-injection-patterns.yaml (primary) with
# inline _pg_get_patterns() as fallback when YAML is unavailable.
# YAML format is Lasso-compatible for upstream pattern sharing.

# Auto-detect YAML patterns file location
_pg_find_yaml_patterns() {
	# Explicit env var takes priority
	if [[ -n "$PROMPT_GUARD_YAML_PATTERNS" ]]; then
		if [[ -f "$PROMPT_GUARD_YAML_PATTERNS" && -r "$PROMPT_GUARD_YAML_PATTERNS" ]]; then
			echo "$PROMPT_GUARD_YAML_PATTERNS"
			return 0
		fi
		_pg_log_warn "Configured YAML patterns are unavailable: $PROMPT_GUARD_YAML_PATTERNS"
		return 2
	fi

	# Try relative to script (repo checkout / worktree)
	local script_relative="${SCRIPT_DIR}/../configs/prompt-injection-patterns.yaml"
	if [[ -f "$script_relative" ]]; then
		echo "$script_relative"
		return 0
	fi

	# Try deployed location
	local deployed="${HOME}/.aidevops/agents/configs/prompt-injection-patterns.yaml"
	if [[ -f "$deployed" ]]; then
		echo "$deployed"
		return 0
	fi

	# Not found — caller should fall back to inline patterns
	return 1
}

# Parse YAML patterns into pipe-delimited severity|category|description|pattern
# records. The YAML structure is intentionally simple and predictable.
_pg_yaml_entry_complete() {
	local severity="$1"
	local description="$2"
	local pattern="$3"
	local category="$4"
	[[ -n "$severity" && -n "$description" && -n "$pattern" && -n "$category" ]]
	return $?
}

_pg_parse_yaml_patterns_file() {
	local yaml_file="$1"
	local patterns=""
	local current_category=""
	local severity="" description="" pattern=""
	local entry_started=0
	local parse_error=0
	local line=""
	while IFS= read -r line; do
		# Skip comments and empty lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue
		# Category header (top-level key ending with colon, no leading whitespace)
		if [[ "$line" =~ ^([a-z_]+):$ ]]; then
			if [[ "$entry_started" -eq 1 ]]; then
				if _pg_yaml_entry_complete "$severity" "$description" "$pattern" "$current_category"; then
					patterns+="${severity}|${current_category}|$(_pg_sanitize_delimited "$description")|${pattern}"$'\n'
				else
					parse_error=1
					break
				fi
			fi
			current_category="${BASH_REMATCH[1]}"
			severity=""
			description=""
			pattern=""
			entry_started=0
			continue
		fi
		# List item start (- severity: ...)
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*severity:[[:space:]]*\"?([A-Z]+)\"?$ ]]; then
			# Emit the previous complete entry. Any partial entry means the
			# configured source is malformed and must not reduce scan coverage.
			if [[ "$entry_started" -eq 1 ]] && \
				_pg_yaml_entry_complete "$severity" "$description" "$pattern" "$current_category"; then
				patterns+="${severity}|${current_category}|$(_pg_sanitize_delimited "$description")|${pattern}"$'\n'
			elif [[ "$entry_started" -eq 1 || -z "$current_category" ]]; then
				parse_error=1
				break
			fi
			severity="${BASH_REMATCH[1]}"
			case "$severity" in
			CRITICAL | HIGH | MEDIUM | LOW) ;;
			*) parse_error=1; break ;;
			esac
			description=""
			pattern=""
			entry_started=1
			continue
		fi
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*severity: ]]; then
			parse_error=1
			break
		fi
		# Description field
		if [[ "$line" =~ ^[[:space:]]*description:[[:space:]]*\"(.+)\"$ ]]; then
			description="${BASH_REMATCH[1]}"
			continue
		fi
		if [[ "$line" =~ ^[[:space:]]*description: ]]; then
			parse_error=1
			break
		fi
		# Pattern field (single-quoted — YAML standard for regex)
		if [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\'(.+)\'$ ]]; then
			pattern="${BASH_REMATCH[1]}"
			continue
		fi
		# Pattern field (double-quoted)
		if [[ "$line" =~ ^[[:space:]]*pattern:[[:space:]]*\"(.+)\"$ ]]; then
			pattern="${BASH_REMATCH[1]}"
			continue
		fi
		if [[ "$line" =~ ^[[:space:]]*pattern: ]]; then
			parse_error=1
			break
		fi
	done <"$yaml_file" || {
		_pg_log_warn "YAML pattern source could not be read: $yaml_file"
		return 2
	}
	# Emit last pattern
	if [[ "$parse_error" -eq 0 && "$entry_started" -eq 1 ]] && \
		_pg_yaml_entry_complete "$severity" "$description" "$pattern" "$current_category"; then
		patterns+="${severity}|${current_category}|$(_pg_sanitize_delimited "$description")|${pattern}"$'\n'
	elif [[ "$entry_started" -eq 1 ]]; then
		parse_error=1
	fi
	if [[ "$parse_error" -ne 0 ]]; then
		_pg_log_warn "YAML pattern source is malformed: $yaml_file"
		return 2
	fi
	if [[ -z "$patterns" ]]; then
		_pg_log_warn "YAML file parsed but no patterns extracted: $yaml_file"
		return 2
	fi

	printf '%s' "${patterns%$'\n'}"
	return 0
}

_pg_load_yaml_patterns() {
	if [[ "$_PG_YAML_PATTERNS_LOADED" == "true" ]]; then
		if [[ -n "$_PG_YAML_PATTERNS_CACHE" ]]; then
			echo "$_PG_YAML_PATTERNS_CACHE"
			return 0
		fi
		_pg_log_warn "YAML pattern cache is marked loaded but empty"
		return 2
	fi

	local yaml_file=""
	local find_status=0
	yaml_file=$(_pg_find_yaml_patterns) || find_status=$?
	if [[ "$find_status" -eq 1 ]]; then
		_pg_log_info "YAML patterns not found, using inline fallback"
		return 1
	fi
	if [[ "$find_status" -ne 0 || -z "$yaml_file" || ! -r "$yaml_file" ]]; then
		_pg_log_warn "YAML pattern source could not be loaded"
		return 2
	fi

	local patterns=""
	patterns=$(_pg_parse_yaml_patterns_file "$yaml_file") || return $?

	# Cache for subsequent calls — mark loaded only after successful parse+cache
	# so transient parse failures do not permanently disable YAML loading.
	_PG_YAML_PATTERNS_CACHE="$patterns"
	_PG_YAML_PATTERNS_LOADED="true"

	echo "$patterns"
	return 0
}

# ============================================================
# PATTERN DEFINITIONS (inline fallback)
# ============================================================
# Each pattern: severity|category|description|regex
# Severity: CRITICAL, HIGH, MEDIUM, LOW
# Categories: role_play, instruction_override, delimiter_injection,
#             encoding_tricks, system_prompt_extraction, social_engineering,
#             data_exfiltration, data_exfiltration_dns, context_manipulation,
#             homoglyph, unicode_manipulation, fake_role, comment_injection,
#             priority_manipulation, fake_delimiter, split_personality,
#             steganographic, fake_conversation, credential_exposure

_pg_get_inline_patterns() {
	# --- CRITICAL: Direct instruction override ---
	cat <<'PATTERNS'
CRITICAL|instruction_override|Ignore previous instructions|[Ii]gnore\s+(all\s+)?(previous|prior|above|earlier|preceding)\s+(instructions|prompts|rules|directives|guidelines|context)
CRITICAL|instruction_override|Disregard system prompt|[Dd]isregard\s+(the\s+)?(system\s+)?(prompt|instructions|rules|guidelines|directives)
CRITICAL|instruction_override|Override system instructions|[Oo]verride\s+(all\s+)?(system\s+)?(instructions|rules|constraints|guidelines|safety)
CRITICAL|instruction_override|New instructions directive|[Nn]ew\s+(system\s+)?instructions?:\s
CRITICAL|instruction_override|You are now a different AI|[Yy]ou\s+are\s+now\s+(a\s+)?(different|new|another|my|an?\s+unrestricted)
CRITICAL|instruction_override|Forget everything|[Ff]orget\s+(everything|all|what)\s+(you|that|about)
CRITICAL|instruction_override|Reset to factory|[Rr]eset\s+(to\s+)?(factory|default|original|initial)\s+(settings|state|mode|instructions)
CRITICAL|system_prompt_extraction|Reveal system prompt|([Rr]eveal|[Ss]how|[Dd]isplay|[Pp]rint|[Oo]utput|[Rr]epeat|[Rr]ecite)\s+(your\s+)?(system\s+)?(prompt|instructions|rules|guidelines|directives|initial\s+prompt)
CRITICAL|system_prompt_extraction|What are your instructions|[Ww]hat\s+(are|were)\s+(your|the)\s+(system\s+)?(instructions|rules|guidelines|directives|constraints|prompt)
CRITICAL|system_prompt_extraction|Copy system prompt verbatim|([Cc]opy|[Pp]aste|[Rr]eproduce|[Dd]ump)\s+(the\s+)?(entire\s+)?(system\s+)?(prompt|instructions|context)(\s+verbatim)?
HIGH|instruction_override|Do not follow rules|[Dd]o\s+not\s+(follow|obey|adhere\s+to|comply\s+with)\s+(the\s+)?(rules|instructions|guidelines|constraints|safety)
HIGH|instruction_override|Pretend you have no restrictions|[Pp]retend\s+(you\s+)?(have\s+)?(no|don.t\s+have\s+any)\s+(restrictions|rules|guidelines|constraints|limitations|safety)
HIGH|instruction_override|Act as if no rules|[Aa]ct\s+(as\s+if|like)\s+(there\s+are\s+)?(no|you\s+have\s+no)\s+(rules|restrictions|guidelines|constraints|limitations)
HIGH|role_play|DAN jailbreak|[Dd]o\s+[Aa]nything\s+[Nn]ow|DAN\s+(mode|prompt|jailbreak)
HIGH|role_play|Developer mode jailbreak|[Dd]eveloper\s+[Mm]ode\s+(enabled|activated|on)|enable\s+developer\s+mode
HIGH|role_play|Jailbreak keyword|[Jj]ailbreak|[Uu]nfiltered\s+mode|[Gg]od\s+mode|[Uu]ncensored\s+mode
HIGH|role_play|Evil/unrestricted persona|([Aa]ct|[Bb]ehave|[Rr]espond)\s+(as|like)\s+(an?\s+)?(evil|malicious|unrestricted|unfiltered|uncensored|unethical)
HIGH|role_play|Opposite day|[Oo]pposite\s+[Dd]ay|[Rr]everse\s+[Mm]ode|[Aa]nti-?(safety|rules|guidelines)
HIGH|delimiter_injection|Markdown system block|```system\b|```\s*system\s*\n|<\|system\|>|<\|im_start\|>\s*system
HIGH|delimiter_injection|XML system tags|<system>|</system>|<\/?system_prompt>|<\/?instructions>
HIGH|delimiter_injection|ChatML injection|<\|im_start\|>|<\|im_end\|>|<\|endoftext\|>
HIGH|data_exfiltration|Exfiltrate via URL|([Ss]end|[Pp]ost|[Tt]ransmit|[Ee]xfiltrate|[Ll]eak)\s+(the\s+)?(data|information|content|secrets?|keys?|tokens?|credentials?)\s+(to|via|through|using)\s+(https?://|a\s+URL|an?\s+endpoint)
HIGH|data_exfiltration|Encode and send|([Ee]ncode|[Bb]ase64|[Hh]ex)\s+(and\s+)?(send|transmit|post|include\s+in)
CRITICAL|data_exfiltration_dns|DNS exfil: dig with command substitution|(?im)(^|[;&|]\s*|:\s*|`{1,2}\s*|\b(run|execute|use)\s+)(sudo\s+|env\s+)?\bdig\s+.*(\$\(|\$\{|`)[^)}`\r\n]*(\)|`|\})
CRITICAL|data_exfiltration_dns|DNS exfil: nslookup with command substitution|(?im)(^|[;&|]\s*|:\s*|`{1,2}\s*|\b(run|execute|use)\s+)(sudo\s+|env\s+)?\bnslookup\s+.*(\$\(|\$\{|`)[^)}`\r\n]*(\)|`|\})
CRITICAL|data_exfiltration_dns|DNS exfil: host with command substitution|(?im)(^|[;&|]\s*|:\s*|`{1,2}\s*|\b(run|execute|use)\s+)(sudo\s+|env\s+)?\bhost\s+.*(\$\(|\$\{|`)[^)}`\r\n]*(\)|`|\})
CRITICAL|data_exfiltration_dns|DNS exfil: base64 data piped to DNS tool|(?i)\bbase64\b.*\|.*\b(dig|nslookup|host)\b
HIGH|data_exfiltration_dns|DNS exfil: variable interpolation with trailing dot|(?i)\b(dig|nslookup|host)\s+.*\$[A-Za-z_{].*\.\s*$
HIGH|data_exfiltration_dns|DNS exfil: encoded data piped to DNS tool|(?i)\b(xxd|od\s+-[AaxX]|hexdump)\b.*\|\s*(dig|nslookup|host)\b
HIGH|data_exfiltration_dns|DNS exfil: TXT record query with dynamic data|(?i)\bdig\s+.*\bTXT\b.*(\$\(|\$\{|`)
HIGH|data_exfiltration_dns|DNS exfil: DNS tool inside loop|(?i)\b(for|while)\b.*\b(dig|nslookup|host)\b.*\bdone\b
HIGH|data_exfiltration_dns|DNS exfil: DNS-over-HTTPS with dynamic data|(?i)(dns-query|dns\.google|cloudflare-dns\.com/dns-query|doh\.).*(\$\(|\$\{|`)
HIGH|fake_role|Fake JSON system role|"role"\s*:\s*"system"|'role'\s*:\s*'system'
HIGH|fake_role|Fake JSON assistant message|"role"\s*:\s*"assistant"|'role'\s*:\s*'assistant'
HIGH|fake_role|Fake XML role tags|<role>system</role>|<role>assistant</role>
HIGH|comment_injection|HTML comment with instructions|<!--\s*(system|ignore|override|instruction|prompt|secret|hidden)
HIGH|comment_injection|Code comment with instructions|//\s*(SYSTEM|OVERRIDE|IGNORE|INSTRUCTION|HIDDEN):|#\s*(SYSTEM|OVERRIDE|IGNORE|INSTRUCTION|HIDDEN):
HIGH|priority_manipulation|Priority override claim|PRIORITY:\s*(HIGHEST|URGENT|OVERRIDE|CRITICAL)|IMPORTANCE:\s*(MAXIMUM|OVERRIDE|HIGHEST)
HIGH|priority_manipulation|Must follow instruction|MUST\s+FOLLOW|MANDATORY\s+INSTRUCTION|REQUIRED\s+ACTION|NON-NEGOTIABLE
HIGH|fake_delimiter|Fake end of prompt|---\s*END\s+(OF\s+)?(SYSTEM\s+)?(PROMPT|INSTRUCTIONS|CONTEXT)\s*---|===\s*END\s+(OF\s+)?(PROMPT|INSTRUCTIONS)\s*===
HIGH|fake_delimiter|Fake begin new section|---\s*BEGIN\s+(NEW\s+)?(SYSTEM\s+)?(PROMPT|INSTRUCTIONS|CONTEXT)\s*---|===\s*BEGIN\s+(NEW\s+)?(PROMPT|INSTRUCTIONS)\s*===
HIGH|split_personality|Evil twin persona|([Yy]our\s+)?(evil|dark|shadow|hidden|true|real)\s+(twin|self|side|personality|persona)\s+(would|should|must|wants?\s+to)
HIGH|split_personality|Split personality attack|([Ss]witch|[Cc]hange|[Aa]ctivate)\s+(to\s+)?(your\s+)?(other|alternate|hidden|secret|true)\s+(personality|persona|mode|self)
MEDIUM|role_play|Roleplay as system|([Rr]oleplay|[Pp]retend|[Ii]magine|[Ss]uppose)\s+(you\s+are|you.re|that\s+you\s+are|that\s+you.re?)\s+(a\s+)?(system|admin|root|superuser|developer|hacker)
MEDIUM|role_play|Hypothetical bypass|([Hh]ypothetically|[Ii]n\s+theory|[Ii]f\s+you\s+could|[Ii]f\s+there\s+were\s+no\s+rules)\s*,?\s*(how\s+would|what\s+would|could\s+you)
MEDIUM|encoding_tricks|Base64 encoded payload|[Dd]ecode\s+(this|the\s+following)\s+(base64|b64)|[Ee]xecute\s+(the\s+)?(decoded|base64)
MEDIUM|encoding_tricks|Hex encoded payload|[Dd]ecode\s+(this|the\s+following)\s+hex|\\x[0-9a-fA-F]{2}(\\x[0-9a-fA-F]{2}){3,}
MEDIUM|encoding_tricks|Unicode escape sequences|\\u[0-9a-fA-F]{4}(\\u[0-9a-fA-F]{4}){3,}
MEDIUM|encoding_tricks|ROT13 or cipher reference|[Dd]ecode\s+(this\s+)?(ROT13|rot13|caesar|cipher)|[Aa]pply\s+(ROT13|rot13)
MEDIUM|encoding_tricks|URL encoded payload|%[0-9a-fA-F]{2}(%[0-9a-fA-F]{2}){5,}
MEDIUM|context_manipulation|Token smuggling|[Ii]nsert\s+(the\s+following\s+)?(into|at\s+the\s+beginning|at\s+the\s+end\s+of)\s+(the\s+)?(context|conversation|prompt|system)
MEDIUM|context_manipulation|Conversation history manipulation|([Mm]odify|[Cc]hange|[Aa]lter|[Ee]dit)\s+(the\s+)?(conversation|chat)\s+(history|context|log)
MEDIUM|social_engineering|Urgency pressure|([Tt]his\s+is\s+(an?\s+)?emergency|[Uu]rgent|[Ii]mmediately|[Rr]ight\s+now|[Ll]ife\s+or\s+death)\s*[,!:]\s*([Yy]ou\s+must|[Ii]gnore|[Bb]ypass|[Oo]verride|[Ss]kip)
MEDIUM|social_engineering|Authority claim|[Ii]\s+(am|.m)\s+(the\s+)?(admin|administrator|developer|owner|creator|CEO|CTO)\s+(of\s+this|and\s+I)
MEDIUM|delimiter_injection|Embedded instructions block|---\s*(SYSTEM|INSTRUCTIONS|RULES)\s*---|===\s*(SYSTEM|INSTRUCTIONS|RULES)\s*===
MEDIUM|priority_manipulation|Instruction priority claim|([Tt]his|[Tt]hese)\s+(instruction|directive|command)s?\s+(has|have|takes?|gets?)\s+(highest|top|maximum|absolute)\s+priority
MEDIUM|priority_manipulation|Supersede instructions|([Tt]his|[Tt]hese)\s+(supersede|override|replace|overwrite)s?\s+(all\s+)?(previous|prior|other|existing)\s+(instructions|rules|directives)
MEDIUM|fake_delimiter|Fake tool output boundary|</?tool_output>|</?function_result>|</?tool_response>|</?api_response>
MEDIUM|fake_delimiter|Fake conversation turn|<\|user\|>|<\|assistant\|>|<\|human\|>|<\|ai\|>
MEDIUM|fake_conversation|Fake previous AI response|([Ii]n\s+)?(my|our)\s+(previous|last|earlier)\s+(response|message|reply|conversation)\s*,?\s*[Ii]\s+(said|told|agreed|confirmed|promised)
MEDIUM|fake_conversation|Fake established agreement|([Ww]e\s+)?(already|previously)\s+(agreed|established|decided|confirmed)\s+(that|to)\s+(you\s+would|you\s+should|you\s+will|I\s+can)
MEDIUM|fake_conversation|Fake continuation claim|([Cc]ontinuing|[Rr]esuming)\s+(from\s+)?(where\s+)?(we|you)\s+(left\s+off|stopped|were)|[Aa]s\s+(we|you)\s+(discussed|agreed)\s+(earlier|before|previously)
MEDIUM|split_personality|Unrestricted mode request|([Ee]nter|[Ss]witch\s+to|[Aa]ctivate|[Ee]nable)\s+(unrestricted|unfiltered|uncensored|raw|unmoderated)\s+(mode|output|response)
LOW|role_play|Generic persona switch|([Aa]ct|[Bb]ehave|[Rr]espond)\s+(as|like)\s+(a|an|the)\s+\w+\s+(who|that|with)\s+(no|ignores?|doesn.t\s+follow)\s+(rules|restrictions|guidelines)
LOW|social_engineering|Emotional manipulation|([Pp]lease|[Ii]\s+beg\s+you|[Ii]\s+really\s+need|[Mm]y\s+life\s+depends)\s*,?\s*(just\s+)?(ignore|bypass|skip|override)\s+(the\s+)?(rules|safety|restrictions|guidelines)
LOW|encoding_tricks|Leetspeak obfuscation|1gn0r3\s+pr3v10us|0v3rr1d3|syst3m\s+pr0mpt|j41lbr34k
LOW|context_manipulation|Invisible characters|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]
LOW|context_manipulation|Zero-width characters|[\x{200B}\x{200C}\x{200D}\x{FEFF}]
LOW|homoglyph|Cyrillic homoglyph characters|\p{Cyrillic}.*(gnore|verride|ystem|rompt|nstruction)
LOW|homoglyph|Greek homoglyph characters|\p{Greek}.*(gnore|verride|ystem|rompt|nstruction)
LOW|unicode_manipulation|Zero-width space sequences|[\x{200B}]{2,}|[\x{200C}]{2,}|[\x{200D}]{2,}
LOW|unicode_manipulation|Mixed script with injection|\p{Cyrillic}[\x00-\x7F]*(nstruction|ommand|xecute|un\b)|\p{Greek}[\x00-\x7F]*(nstruction|ommand|xecute|un\b)
LOW|steganographic|Acrostic instruction pattern|[A-Z][a-z]+\s*\n[A-Z][a-z]+\s*\n[A-Z][a-z]+\s*\n[A-Z][a-z]+\s*\n[A-Z][a-z]+
LOW|system_prompt_extraction|System prompt extraction variant|([Ww]rite|[Tt]ype|[Oo]utput)\s+(out\s+)?(the\s+)?(text|content|words)\s+(above|before|preceding)\s+(this|my)\s+(message|input|prompt)
LOW|system_prompt_extraction|Prompt leak via translation|([Tt]ranslate|[Cc]onvert)\s+(your\s+)?(system\s+)?(prompt|instructions|rules)\s+(to|into)\s+(French|Spanish|Chinese|another\s+language)
MEDIUM|credential_exposure|URL query param: secret|[?&]secret=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: token|[?&]token=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: key/api_key|[?&](key|api_key|apikey|api-key)=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: password|[?&]password=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: access_token|[?&]access_token=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: auth|[?&](auth|authorization)=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: client_secret|[?&]client_secret=[^&\s]{8,}
MEDIUM|credential_exposure|URL query param: webhook_secret|[?&]webhook_secret=[^&\s]{8,}
PATTERNS
	return 0
}

_pg_get_patterns() {
	# Inline patterns — always available as fallback.
	# YAML vs inline routing is handled by _pg_scan_message() which calls
	# _pg_load_yaml_patterns() directly. This function is the inline-only path.
	_pg_get_inline_patterns
	return 0
}
