#!/bin/bash
trap '' SIGPIPE

# Interval between checking container status (in seconds)
CONTAINER_STATUS_INTERVAL=10

# Interval between checking the list of Datadog agent pods (in seconds)
AGENT_POD_LIST_INTERVAL=60

# Application container name to check (appli/service)
APPLICATION_NAME="echo-app"
APPLICATION_CONTAINER_NAME="echo-bash"
APPLICATION_SERVICE="echo-app"
SEARCH_FOR="Hello"

AGENT_MAP_FILE=agent_map_file.txt
VERBOSE=false
TYPE_FILTER="all"
DRY_RUN=false
LAST_POD_LIST_FETCH=0
WATCH_MODE=false

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -t, --type <type>     Specify which from_ function(s) to run:
                          kubectl   : Run from_kubectl_logs
                          tail      : Run from_tail_container_logs_file_in_agent_pod
                          stream    : Run from_agent_streamlogs
                          all       : Run all (default)
  -w, --watch           Watch for new pods instead of polling every ${CONTAINER_STATUS_INTERVAL}s
  -n, --dry-run         Show the commands without executing them.
  -v                    Enable verbose mode (echo internal debug info)
  -h, --help            Show this help message and exit

Examples:
  $0 -t kubectl
  $0 -t tail -v
  $0 -t stream --dry-run
  $0 -v -w | grep app
  $0 -h
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--type)
      TYPE_FILTER="$2"
      shift 2
      ;;
    -v)
      VERBOSE=true
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -w|--watch)
      WATCH_MODE=true
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
done

vecho() {
    if [ "$VERBOSE" = true ]; then
      printf "[%s] [INFO] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$@" 2>/dev/null || true
    fi
}

# Prefix each log line with timestamp and source info
prefix_log_lines() {
    local source="$1"
    while IFS= read -r line; do
        printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$source" "$line" 2>/dev/null || true
    done
}

PIDS=()

kill_with_log() {
  local pattern="$1"
  ps -eo pid,command | grep "$pattern" | grep -v grep | while read -r pid cmd; do 
  vecho "Killing PID $pid: $cmd"
  kill -9 "$pid" 2>/dev/null
  done
}

cleanup() {
    vecho "Cleaning up background tail processes..."
    for pid in "${PIDS[@]}"; do
        vecho "Killing PID: $pid"
        kill "$pid" 2>/dev/null
    done
    kill_with_log "kubectl exec .* tail -f"
    kill_with_log "kubectl exec -c agent datadog-agent-.* -- agent stream-logs .*"
    kill_with_log "kubectl logs -f .*"
    exit
}
trap cleanup EXIT SIGINT SIGTERM

is_command_running() {
    local raw_command="$1"
    local search_string="${raw_command//\"/}"

    if pgrep -af "$search_string" | grep -v grep > /dev/null; then
        return 0
    else
        return 1
    fi
}

get_agent_pod_for_node() {
    local search_node="$1"
    grep "^$search_node " "$AGENT_MAP_FILE" | awk '{print $2}'
}

from_kubectl_logs() {
    local app_pod_node=$1
    local pod=$2
    local container=$3
    local agent_pod
    agent_pod=$(get_agent_pod_for_node "$app_pod_node")
      local k8s_logs_command="kubectl logs -f \"$pod\" -c \"$container\""
    if [[ "$DRY_RUN" == true ]]; then
    	echo "[DRY-RUN] $k8s_logs_command"
    else
    	if ! is_command_running "$k8s_logs_command"; then
        local source="KUBECTL_LOGS: AGENT($agent_pod)/APP($app_pod_node/$pod/$container)"
        (
            eval "$k8s_logs_command" 2>/dev/null | grep -E --line-buffered "$SEARCH_FOR" | prefix_log_lines "$source"
        ) &
        fi
    fi
    PIDS+=($!)
}

from_tail_container_logs_file_in_agent_pod() {
    local app_pod_node=$1
    local agent_pod
    app_pod=$2
    agent_pod=$(get_agent_pod_for_node "$app_pod_node")
    local log_paths
    log_paths=$(kubectl exec -c agent "$agent_pod" -- agent status 2>/dev/null | grep "Inputs:" -A1 | grep "$APPLICATION_CONTAINER_NAME" | grep "$APPLICATION_NAME" | grep "$app_pod" | sort -u )
    echo "$log_paths" | while read -r log_path; do
    local tail_command="kubectl exec -c agent \"$agent_pod\" -- tail -f \"$log_path\""
    local source="TAIL: FILE($log_path)/AGENT($app_pod_node/$agent_pod)/APP($APPLICATION_NAME/$APPLICATION_CONTAINER_NAME)"
    if [[ "$DRY_RUN" == true ]]; then
    	echo "[DRY-RUN] $tail_command"
    else
   	if ! is_command_running "$tail_command"; then
    	vecho "Fetching and tailing logs from $log_path in pod $agent_pod..."
            (
                eval "$tail_command" 2>/dev/null | grep -E --line-buffered "$SEARCH_FOR" | prefix_log_lines "$source"
            ) &
        fi
    fi
            PIDS+=($!)
    done
}

from_agent_streamlogs() {
    local app_pod_node=$1
    local app_pod=$2
    local agent_pod
    agent_pod=$(get_agent_pod_for_node "$app_pod_node")

    local streamlogs_command="kubectl exec -c agent ${agent_pod} -- agent stream-logs --service $APPLICATION_SERVICE -o /tmp/${app_pod} -d 10s"
    local source="AGENT_STREAMLOGS: AGENT($agent_pod)/APP($APPLICATION_SERVICE/$APPLICATION_NAME/$APPLICATION_CONTAINER_NAME)"
    if [[ "$DRY_RUN" == true ]]; then
    	echo "[DRY-RUN] $streamlogs_command"
    else
        if ! is_command_running "$streamlogs_command"; then
        vecho "Fetching logs from Datadog agent stream-logs for pod $agent_pod..."
        (
            eval "$streamlogs_command" 2>/dev/null | grep -E --line-buffered "$SEARCH_FOR" | prefix_log_lines "$source"
        ) &
        
        fi
    fi
        PIDS+=($!)
}

check_container_status() {
    local agent_pod=$1
    local pod=$2
    local container=$3
    local app_pod_node=$4

    container_status=$(kubectl get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$container\")].state}" 2>/dev/null)

    if echo "$container_status" | grep -qE "running"; then
        vecho "Container $container is running in pod $pod on node $app_pod_node. Executing from_* functions..."

        case "$TYPE_FILTER" in
          kubectl|all)
            from_kubectl_logs "$app_pod_node" "$pod" "$container"
            ;;
        esac

        case "$TYPE_FILTER" in
          tail|all)
            from_tail_container_logs_file_in_agent_pod "$app_pod_node" "$pod"
            ;;
        esac

        case "$TYPE_FILTER" in
          stream|all)
            from_agent_streamlogs "$app_pod_node" "$pod"
            ;;
        esac
    fi
}

refresh_agent_pod_map() {
  while true; do
    vecho "Refreshing Datadog agent pod map..."
    check_datadog_agent_pods
    sleep "$AGENT_POD_LIST_INTERVAL"
  done
} 

check_datadog_agent_pods() {
    vecho "List of Datadog agent pods:"
    vecho "Building Datadog agent pod list..."

    > "$AGENT_MAP_FILE"
    JSONPATH='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}'
    kubectl get pods -l app=datadog-agent -o jsonpath="$JSONPATH" | while read -r pod_agent_name app_pod_node; do
        echo "$app_pod_node $pod_agent_name" >> "$AGENT_MAP_FILE" && vecho "$app_pod_node $pod_agent_name"
    done
}

process_running_pods() {
    vecho "Processing currently running pods..."
    JSONPATH='{range .items[?(@.metadata.labels.job-name)]}{.metadata.name} {.spec.nodeName}{"\n"}{end}'
    kubectl get pods -l app=$APPLICATION_NAME -o jsonpath="$JSONPATH" | while read -r pod_name app_pod_node; do
       if [[ -n "$pod_name" && -n "$app_pod_node" ]]; then
            check_container_status "$agent_pod" "$pod_name" "$APPLICATION_CONTAINER_NAME" "$app_pod_node"
        fi
    done
    if [[ "$DRY_RUN" == true ]]; then
      exit 0
    fi
}
watch_new_pods() {
  vecho "Watching for new pod events..."
  line_count=0
  kubectl get pods -w -l app=$APPLICATION_NAME | while read -r line; do
    ((line_count++))

    # Skip header and initial dump (~first 10 lines or so)
    if [[ "$line_count" -le 10 ]]; then
      continue
    fi

    if echo "$line" | grep -q "Running"; then
      pod_name=$(echo "$line" | awk '{print $1}')
      node_name=$(kubectl get pod "$pod_name" -o jsonpath='{.spec.nodeName}')
      vecho "new pod event: node=$node_name, pod=$pod_name"

      if [[ -n "$pod_name" && -n "$node_name" ]]; then
        agent_pod=$(get_agent_pod_for_node "$node_name")
        check_container_status "$agent_pod" "$pod_name" "$APPLICATION_CONTAINER_NAME" "$node_name"
      fi
    fi
  done
}


# Main loop to check Datadog agent pods and application container status at different intervals
refresh_agent_pod_map &  # update agent map every X seconds
PIDS+=($!)
if [[ "$WATCH_MODE" == true ]]; then
  process_running_pods
  watch_new_pods
else
  while true; do
    process_running_pods
    vecho "$current_time Waiting for $CONTAINER_STATUS_INTERVAL seconds before the next check..."
    sleep "$CONTAINER_STATUS_INTERVAL"
  done
fi
