#!/usr/bin/env bash

set -euo pipefail

source_bundle="${1:-}"
destination_bundle="/Applications/XDial.app"
health_url="http://127.0.0.1:19876/health"
state_url="http://127.0.0.1:19876/state"
action_url="http://127.0.0.1:19876/action"
probe_url="${XDIAL_RESTART_PROBE_URL:-https://www.apple.com/}"

fail() {
	echo "✗ $*" >&2
	exit 1
}

json_pid() {
	python3 -c \
		'import json,sys; print(json.load(sys.stdin).get("pid", ""))'
}

state_fields() {
	python3 -c '
import json, sys
d = json.load(sys.stdin)
engine = d.get("engine") or {}
report = d.get("connectionReport") or {}
automatic = d.get("automaticReconnect") or {}
installation = d.get("installationReport") or {}
baseline_transaction_id = sys.argv[1]
restart_started_at = float(sys.argv[2])
transaction_id = str(report.get("transaction_id", ""))
report_is_new = False
if transaction_id:
    if baseline_transaction_id:
        report_is_new = transaction_id != baseline_transaction_id
    else:
        try:
            report_is_new = float(report.get("started_at", 0)) >= restart_started_at
        except (TypeError, ValueError):
            report_is_new = False
values = [
    installation.get("state", ""),
    d.get("desiredConnectionState", ""),
    engine.get("status", ""),
    "1" if engine.get("isBusy", False) else "0",
    report.get("state", ""),
    "1" if report.get("error") else "0",
    str(automatic.get("attempts_used", 0)),
    transaction_id,
    "1" if report_is_new else "0",
]
print("|".join(str(value) for value in values))
' "${1:-}" "${2:-0}"
}

[[ -n "${source_bundle}" ]] || fail "missing source app bundle"
[[ -d "${source_bundle}" ]] || fail "source app does not exist: ${source_bundle}"
[[ -x "${source_bundle}/Contents/MacOS/XDial" ]] \
	|| fail "source app executable is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# Swift 的 JSONEncoder 使用 2001-01-01 作为 Date 基准。向前留一秒只用于
# 容纳序列化到整数秒时的取整；transaction ID 是有旧实例时的首选边界。
restart_started_at="$(( $(date +%s) - 978307200 - 1 ))"
baseline_reconnect_attempts=0
baseline_transaction_id=""
baseline_report_failed=0

# 所有会影响当前实例的动作之前，先完整验证构建产物。
/usr/bin/codesign --verify --deep --strict "${source_bundle}" \
	|| fail "built app failed signature validation"

old_pid=""
if health_json="$(curl -fsS --max-time 2 "${health_url}" 2>/dev/null)"; then
	old_pid="$(printf '%s' "${health_json}" | json_pid)"
	[[ "${old_pid}" =~ ^[0-9]+$ ]] \
		|| fail "Debug Server health response did not identify XDial"
	old_state_json="$(curl -fsS --max-time 2 "${state_url}" 2>/dev/null)" \
		|| fail "could not capture restart state baseline"
	baseline_fields="$(
		printf '%s' "${old_state_json}" \
			| state_fields "" "${restart_started_at}"
	)"
	IFS='|' read -r _ _ _ _ baseline_report_state \
		baseline_has_error baseline_reconnect_attempts \
		baseline_transaction_id _ <<< "${baseline_fields}"
	if [[ "${baseline_report_state}" == "failed" \
		|| "${baseline_has_error}" == "1" ]]; then
		baseline_report_failed=1
	fi
	curl -fsS --max-time 5 -X POST "${action_url}" \
		-d '{"action":"quit"}' >/dev/null || true
elif pgrep -x XDial >/dev/null 2>&1; then
	fail "XDial is running without Debug Server; refusing to force it closed"
fi

if [[ -n "${old_pid}" ]]; then
	for _ in {1..120}; do
		kill -0 "${old_pid}" 2>/dev/null || break
		sleep 0.25
	done
	kill -0 "${old_pid}" 2>/dev/null \
		&& fail "old XDial did not complete graceful shutdown"
fi

# 旧事务回滚后，先证明原网络恢复；否则不把一次必然失败的自动连接叫重启。
underlay_ready=0
for _ in {1..40}; do
	if curl -fsS --max-time 3 -o /dev/null "${probe_url}"; then
		underlay_ready=1
		break
	fi
	sleep 0.5
done
if [[ "${underlay_ready}" != "1" ]]; then
	[[ -d "${destination_bundle}" ]] && open -n "${destination_bundle}"
	fail "original network did not recover; reopened the installed app"
fi

# 仅安装：该进程不创建 AppState、Debug Server 或网络连接。
if ! "${source_bundle}/Contents/MacOS/XDial" --install-only; then
	[[ -d "${destination_bundle}" ]] && open -n "${destination_bundle}"
	fail "atomic app replacement failed"
fi

open -n "${destination_bundle}"

new_pid=""
for _ in {1..60}; do
	if health_json="$(curl -fsS --max-time 1 "${health_url}" 2>/dev/null)"; then
		candidate_pid="$(printf '%s' "${health_json}" | json_pid)"
		candidate_command="$(ps -p "${candidate_pid}" -o command= 2>/dev/null || true)"
		if [[ "${candidate_command}" == \
			"${destination_bundle}/Contents/MacOS/XDial" ]]; then
			new_pid="${candidate_pid}"
			break
		fi
	fi
	sleep 0.5
done
[[ -n "${new_pid}" ]] || fail "final /Applications process did not start"

saw_failed_connection=0
ready_state=""
transaction_id=""
for _ in {1..120}; do
	if state_json="$(curl -fsS --max-time 2 "${state_url}" 2>/dev/null)"; then
		fields="$(
			printf '%s' "${state_json}" \
				| state_fields \
					"${baseline_transaction_id}" \
					"${restart_started_at}"
		)"
		IFS='|' read -r installation_state desired_state engine_state \
			is_busy report_state has_error reconnect_attempts transaction_id \
			report_is_new \
			<<< "${fields}"

		report_failed=0
		if [[ "${report_state}" == "failed" \
			|| "${has_error}" == "1" ]]; then
			report_failed=1
		fi
		if [[ "${report_failed}" == "1" \
			&& ( "${report_is_new}" == "1" \
				|| ( -n "${baseline_transaction_id}" \
					&& "${transaction_id}" == \
						"${baseline_transaction_id}" \
					&& "${baseline_report_failed}" == "0" ) ) ]]; then
			saw_failed_connection=1
		fi
		# attempts_used 是尚未稳定五分钟的预算使用量，不是本次命令的
		# 失败总数。只看相对启动 baseline 的新增值；新进程把预算清零
		# 时先下调 baseline，不能把旧实例已有的非零值当成新失败。
		if [[ "${reconnect_attempts}" -lt \
			"${baseline_reconnect_attempts}" ]]; then
			baseline_reconnect_attempts="${reconnect_attempts}"
		elif [[ "${reconnect_attempts}" -gt \
			"${baseline_reconnect_attempts}" ]]; then
			saw_failed_connection=1
		fi

		if [[ "${installation_state}" == "ready" ]]; then
			if [[ "${desired_state}" == "connected" \
				&& "${engine_state}" == "connected" \
				&& "${report_state}" == "committed" ]]; then
				ready_state="connected"
				break
			fi
			if [[ "${desired_state}" != "connected" \
				&& "${is_busy}" == "0" ]]; then
				ready_state="disconnected"
				break
			fi
		fi
	fi
	sleep 0.5
done

[[ -n "${ready_state}" ]] || fail "app started, but runtime did not converge"
[[ "${saw_failed_connection}" == "0" ]] \
	|| fail "connection recovered only after a failed attempt; restart is not accepted"

if [[ "${ready_state}" == "connected" ]]; then
	curl -fsS --max-time 8 -o /dev/null "${probe_url}" \
		|| fail "transaction committed, but real HTTPS failed"
	echo "✓ XDial restarted: pid=${new_pid} transaction=${transaction_id} HTTPS=ready"
else
	echo "✓ XDial restarted: pid=${new_pid} intentionally disconnected"
fi
