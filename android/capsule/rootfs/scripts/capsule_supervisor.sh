#!/system/bin/sh
set -euo pipefail

STATE_DIR="/run/capsule"
PID_DIR="${STATE_DIR}/pids"
LOG_FILE="${STATE_DIR}/capsule-supervisor.log"

export PATH="/system/bin:/system/xbin:/usr/local/bin:${PATH:-}"
export LD_LIBRARY_PATH="/system/lib64:/system/lib:${LD_LIBRARY_PATH:-}"

if [ "${1:-}" != "status" ]; then
	mkdir -p "${PID_DIR}"
	touch "${LOG_FILE}"
fi

log() {
	printf 'capsule_supervisor: %s\n' "$*" >&2
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"${LOG_FILE}"
}

set_ready_prop() {
	val="$1"
	/system/bin/setprop capsule.ready "$val" >/dev/null 2>&1 || true
	/system/bin/setprop sys.capsule.ready "$val" >/dev/null 2>&1 || true
	/system/bin/setprop vendor.capsule.ready "$val" >/dev/null 2>&1 || true
}

service_pid_file() {
	printf '%s/%s.pid\n' "${PID_DIR}" "$1"
}

start_service() {
	name="$1"
	shift
	if [ -z "${1:-}" ]; then
		log "start_service ${name}: no command provided"
		return 1
	fi
	cmd="$*"
	log "starting ${name}: ${cmd}"
	"$@" >>"${LOG_FILE}" 2>&1 &
	pid=$!
	printf '%s\n' "${pid}" >"$(service_pid_file "${name}")"
}

stop_service() {
	name="$1"
	pid_file="$(service_pid_file "${name}")"
	if [ ! -f "${pid_file}" ]; then
		return
	fi
	pid="$(cat "${pid_file}")"
	if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
		log "stopping ${name} (pid ${pid})"
		kill "${pid}" 2>/dev/null || true
		wait "${pid}" 2>/dev/null || true
	fi
	rm -f "${pid_file}"
}

stop_all() {
	for svc in hwservicemanager servicemanager; do
		stop_service "${svc}"
	done
}

all_services_healthy() {
	for svc in servicemanager hwservicemanager; do
		pid_file="$(service_pid_file "${svc}")"
		if [ ! -f "${pid_file}" ]; then
			return 1
		fi
		pid="$(cat "${pid_file}")"
		if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
			return 1
		fi
	done
	return 0
}

ensure_service_running() {
	name="$1"
	shift
	pid_file="$(service_pid_file "${name}")"
	if [ -f "${pid_file}" ]; then
		pid="$(cat "${pid_file}")"
		if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
			return
		fi
	fi
	start_service "${name}" "$@"
}

daemon() {
	log "capsule supervisor daemon starting"

	trap 'log "terminating"; set_ready_prop 0; stop_all; exit 0' INT TERM HUP

	set_ready_prop 0

	ensure_service_running servicemanager /system/bin/servicemanager
	ensure_service_running hwservicemanager /system/bin/hwservicemanager

	# Wait for binder managers to publish themselves before marking ready.
	for _ in 1 2 3 4 5; do
		if all_services_healthy; then
			set_ready_prop 1
			break
		fi
		sleep 0.5
	done

	log "entering monitor loop"
	while true; do
		ensure_service_running servicemanager /system/bin/servicemanager
		ensure_service_running hwservicemanager /system/bin/hwservicemanager

		if ! all_services_healthy; then
			set_ready_prop 0
		else
			set_ready_prop 1
		fi

		sleep 2
	done
}

status() {
    for svc in servicemanager hwservicemanager; do
		pid_file="$(service_pid_file "${svc}")"
		if [ -f "${pid_file}" ]; then
			pid="$(cat "${pid_file}")"
			if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
				state="running (pid ${pid})"
			else
				state="pid file present but process not running"
			fi
		else
			state="not running"
		fi
		printf '%s: %s\n' "${svc}" "${state}"
	done
    printf 'capsule.ready=%s\n' "$(/system/bin/getprop capsule.ready 2>/dev/null)"
    printf 'sys.capsule.ready=%s\n' "$(/system/bin/getprop sys.capsule.ready 2>/dev/null)"
    printf 'vendor.capsule.ready=%s\n' "$(/system/bin/getprop vendor.capsule.ready 2>/dev/null)"
}

case "${1:-}" in
	daemon)
		shift
		daemon "$@"
		;;
	status)
		status
		;;
	*)
		cat <<'EOF' >&2
Usage: capsule_supervisor.sh <daemon|status>
  daemon   Launch servicemanager and hwservicemanager and monitor them.
  status   Print supervisor state (pids and readiness properties).
EOF
		exit 1
		;;
esac
