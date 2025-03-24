# tail_logs

## How to implement a sandbox to test the logs.sh script:

Start minukube with 3 nodes:
```
minikube start --nodes 3 -p multinode-demo
```
Deploy the application(kind CronJob) that will pop on random a node every 6 minutes and echo in stdout every 10 seconds for a duration 6 to 10 minutes.
```
kubectl apply -f echo-cronjob.yaml
```
Deploy Datadog agent in daemonset via helm
```
helm install datadog-agent -f datadog-values.yaml datadog/datadog
```
Verify that the pods are existing/running:
```
kubectl get pods
NAME                                           READY   STATUS             RESTARTS      AGE
datadog-agent-25dvn                            2/2     Running            0             20h
datadog-agent-cluster-agent-5c6fbc58bd-2lfpz   1/1     Running            0             28h
datadog-agent-cluster-agent-6d5756d9db-kjdt9   1/1     Running            0             3m3s
datadog-agent-sqdd7                            2/2     Running            0             11s
datadog-agent-z57bj                            2/2     Running            0             20h
echo-app-cronjob-29047122-wmlp2                0/1     Completed          0             23m
echo-app-cronjob-29047128-ltmk2                0/1     Completed          0             17m
echo-app-cronjob-29047134-6mnnc                0/1     Completed          0             11m
echo-app-cronjob-29047140-dwvbd                1/1     Running            0             5m48s
```

## How to use the script logs.sh:

modify the variables in the script:
```
# Application container name to check (appli/service)
APPLICATION_NAME="echo-app"
APPLICATION_CONTAINER_NAME="echo-bash"
APPLICATION_SERVICE="echo-app"
SEARCH_FOR="Hello"
```


```
./logs.sh -h
Usage: ./logs.sh [OPTIONS]

Options:
  -t, --type <type>     Specify which from_ function(s) to run:
                          kubectl   : Run from_kubectl_logs
                          tail      : Run from_tail_container_logs_file_in_agent_pod
                          stream    : Run from_agent_streamlogs
                          all       : Run all (default)
  -w, --watch           Watch for new pods instead of polling every 10s
  -n, --dry-run         Show the commands without executing them.
  -v                    Enable verbose mode (echo internal debug info)
  -h, --help            Show this help message and exit

Examples:
  ./logs.sh -t kubectl
  ./logs.sh -t tail -v
  ./logs.sh -t stream --dry-run
  ./logs.sh -v -w | grep app
  ./logs.sh -h
```


--dry-run :
```
./logs.sh -n
[DRY-RUN] kubectl logs -f "echo-app-cronjob-29047146-8qv26" -c "echo-bash"
[DRY-RUN] kubectl exec -c agent "datadog-agent-z57bj" -- tail -f "/var/log/pods/default_echo-app-cronjob-29047146-8qv26_debca3fe-8eab-47f5-8cff-623e9e5acd6c/echo-bash/0.log"
[DRY-RUN] kubectl exec -c agent datadog-agent-z57bj -- agent stream-logs --service echo-app -o /tmp/echo-app-cronjob-29047146-8qv26 -d 10s
```

only kubectl logs type with verbose:
```
./logs.sh -t kubectl -v 
[2025-03-24 16:11:54] [INFO] Refreshing Datadog agent pod map...
[2025-03-24 16:11:54] [INFO] Processing currently running pods...
[2025-03-24 16:11:54] [INFO] List of Datadog agent pods:
[2025-03-24 16:11:54] [INFO] Building Datadog agent pod list...
[2025-03-24 16:11:54] [INFO] multinode-demo datadog-agent-25dvn
[2025-03-24 16:11:54] [INFO] multinode-demo-m02 datadog-agent-sqdd7
[2025-03-24 16:11:54] [INFO] multinode-demo-m03 datadog-agent-z57bj
[2025-03-24 16:11:54] [INFO] Container echo-bash is running in pod echo-app-cronjob-29047146-8qv26 on node multinode-demo-m03. Executing from_* functions...
[2025-03-24 16:11:54] [INFO]  Waiting for 10 seconds before the next check...
[2025-03-24 16:11:54] [KUBECTL_LOGS: AGENT(datadog-agent-z57bj)/APP(multinode-demo-m03/echo-app-cronjob-29047146-8qv26/echo-bash)] Hello from echo-app-cronjob-29047146-8qv26 at Mon Mar 24 15:06:01 UTC 2025
[2025-03-24 16:11:54] [KUBECTL_LOGS: AGENT(datadog-agent-z57bj)/APP(multinode-demo-m03/echo-app-cronjob-29047146-8qv26/echo-bash)] Hello from echo-app-cronjob-29047146-8qv26 at Mon Mar 24 15:06:11 UTC 2025
[2025-03-24 16:11:54] [KUBECTL_LOGS: AGENT(datadog-agent-z57bj)/APP(multinode-demo-m03/echo-app-cronjob-29047146-8qv26/echo-bash)] Hello from echo-app-cronjob-29047146-8qv26 at Mon Mar 24 15:06:21 UTC 2025
```

all sources with --watch:
```
./logs.sh -w
[2025-03-24 16:22:12] [AGENT_STREAMLOGS: AGENT(datadog-agent-b8cpc)/APP(echo-app/echo-app/echo-bash)] Integration Name: default/echo-app-cronjob-29047158-wbzg2/echo-bash | Type: file | Status: info | Timestamp: 2025-03-24 15:22:12.043797671 +0000 UTC | Hostname: multinode-demo-m03 | Service: echo-app | Source: echo-app | Tags: filename:0.log,dirname:/var/log/pods/default_echo-app-cronjob-29047158-wbzg2_1896c1d3-f65a-4d30-aa0e-679e640c5ed0/echo-bash,kube_namespace:default,pod_phase:running,image_name:busybox,short_image:busybox,image_id:busybox@sha256:37f7b378a29ceb4c551b1b5582e27747b855bbfaa73fa11914fe0df028dc581f,env:dev,kube_qos:BestEffort,kube_ownerref_kind:job,kube_cronjob:echo-app-cronjob,kube_container_name:echo-bash,image_tag:latest,service:www.echo.app,docker_image:busybox:latest,kube_ownerref_name:echo-app-cronjob-29047158,kube_job:echo-app-cronjob-29047158,pod_name:echo-app-cronjob-29047158-wbzg2,container_id:ce54f101412dfcace8a23d5fc207ae82555e7b952d7945e84e77e0ebab5def9e,display_container_name:echo-bash_echo-app-cronjob-29047158-wbzg2,container_name:echo-bash | Message: Hello from echo-app-cronjob-29047158-wbzg2 at Mon Mar 24 15:22:11 UTC 2025
[2025-03-24 16:22:21] [KUBECTL_LOGS: AGENT(datadog-agent-b8cpc)/APP(multinode-demo-m03/echo-app-cronjob-29047158-wbzg2/echo-bash)] Hello from echo-app-cronjob-29047158-wbzg2 at Mon Mar 24 15:22:21 UTC 2025
[2025-03-24 16:22:22] [TAIL: FILE(/var/log/pods/default_echo-app-cronjob-29047158-wbzg2_1896c1d3-f65a-4d30-aa0e-679e640c5ed0/echo-bash/0.log)/AGENT(multinode-demo-m03/datadog-agent-b8cpc)/APP(echo-app/echo-bash)] {"log":"Hello from echo-app-cronjob-29047158-wbzg2 at Mon Mar 24 15:22:21 UTC 2025\n","stream":"stdout","time":"2025-03-24T15:22:21.666765884Z"}
```

## Functionnalities:
- can detect new application pod from the kubectl command output. (--watch option)
- dry-run to display the current commands to execute.
- kill all the tails commands that has been started from the script when stopping it.

Known issues:
```
the -t stream seems to often stop to tail with this current error:
Another client is already streaming logs.
```
The workaround was to add -d 10s to the actual agent stream-logs command to make it force stopping after 10 seconds([source](https://github.com/ddalexvea/tail_logs/blob/main/logs.sh#L180))
