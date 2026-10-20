# PPU Distributed Job Action

A GitHub composite action that submits and manages framework-agnostic distributed jobs
(from a single card up to multi-node, multi-card) on a Kubernetes PPU cluster.

The action runs on a CPU-only orchestration runner and consumes no accelerator itself.
All PPU resources are requested by the worker pods it creates.

## Features

- Declarative inputs: node count, cards per node, image and command.
- Gang scheduling through `PodGroup` with a dedicated `ppu-scheduler` and
  multi-node pod anti-affinity.
- Standard distributed environment contract injected into every worker pod.
- Automatic source staging: `$GITHUB_WORKSPACE` (plus optional artifacts) is packed and
  extracted inside the worker pod.
- Default CPU/memory limits derived from board type and card count.
- Live log streaming, explicit pending status, timeout handling and cancellation-safe cleanup.
- One-line `PPU usage` notice on the run page plus a collapsed usage summary in the job log, covering queue time and occupied/execution PPU card-hours; the GitHub Job Summary is left untouched.
- One `PPU queue` annotation emitted after the job ends, listing each pod's queue time (creation until scheduling). It is a warning with the latest scheduling failure reason when any pod queued for five minutes or more or never scheduled, and a notice otherwise. Apart from these two and errors, the action creates no run annotations.
- Optional kernel log (`dmesg`) collection from worker nodes.

## Usage

```yaml
jobs:
  train:
    runs-on: <cpu-orchestration-runner-label>
    steps:
      - uses: actions/checkout@v4

      - uses: t-head/ppu-scheduler-action@main
        with:
          image: <registry>/<image>:<tag>
          nnodes: 2
          nproc_per_node: 8
          node_selector: board-type=ZW-M890P
          timeout_minutes: 120
          command: |
            torchrun \
              --nnodes=$NNODES --nproc_per_node=$NPROC_PER_NODE \
              --node_rank=$NODE_RANK \
              --master_addr=$MASTER_ADDR --master_port=$MASTER_PORT \
              train.py
```

### Execution modes

| `nnodes` | Mode | Behavior |
|----------|------|----------|
| `0` (default) | Single pod | One pod, no `PodGroup` or headless `Service` |
| `1..N` | Gang | `N` worker pods, a `PodGroup` (`minMember=N`) and a headless `Service` for rendezvous |

## Inputs

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `image` | yes | | Container image with job code and dependencies |
| `command` | yes | | Shell command executed in each worker pod (`/bin/bash -c`) |
| `nnodes` | no | `0` | Number of worker pods |
| `nproc_per_node` | no | `1` | PPU cards requested per pod (`alibabacloud.com/ppu`) |
| `namespace` | no | `default` | Kubernetes namespace |
| `timeout_minutes` | no | `60` | Job timeout; the job is cleaned up and marked failed on expiry |
| `host_volumes` | no | | `/host/a:/ctr/a,/host/b:/ctr/b`; NAS mounts are added by default |
| `extra_env` | no | | `KEY1=VAL1,KEY2=VAL2` |
| `master_port` | no | `29500` | Rendezvous port |
| `cleanup_policy` | no | `always` | `always`, `on_success` or `never` |
| `source_dir` | no | `/workspace/source` | Path where staged source is extracted in the pod |
| `node_selector` | no | | `KEY1=VAL1,...`, merged into `spec.nodeSelector` |
| `container_options` | no | | YAML snippet, see below |
| `artifact_paths` | no | | Extra paths (one per line) staged with the source |
| `job_suffix` | no | | Readable segment of resource names; a unique hash is always appended |
| `dmesg_policy` | no | `never` | `never`, `on_failure` or `always` |

### `container_options`

| Key | Maps to |
|-----|---------|
| `privileged` | container `securityContext.privileged` |
| `host_ipc` | pod `spec.hostIPC` |
| `host_network` | pod `spec.hostNetwork` (sets `dnsPolicy: ClusterFirstWithHostNet`) |
| `dns_policy` | pod `spec.dnsPolicy` |
| `shm_size` | `/dev/shm` emptyDir `sizeLimit` (default `64Gi`) |
| `cap_add` | `securityContext.capabilities.add`, comma separated |
| `cpus` / `cpu` | `resources.limits.cpu` |
| `memory` | `resources.limits.memory`; docker units `b/k/m/g/t` are converted |

When `cpus` or `memory` is not set, limits are computed per card:
`ZW-M890P` uses 31 cores and 256Gi, `OAM-810E` uses 11 cores and 112Gi.
Without a `board-type` selector, `OAM-810E` values are used.

## Environment contract

Each worker pod receives:

| Variable | Value |
|----------|-------|
| `NNODES` / `WORLD_SIZE` | Number of worker pods |
| `NPROC_PER_NODE` | Cards per pod |
| `NODE_RANK` / `RANK` | Pod index |
| `LOCAL_RANK` | `0` |
| `MASTER_ADDR` | DNS name of worker 0 via the headless `Service` |
| `MASTER_PORT` | `master_port` input |
| `NODE_NAME` | Kubernetes node name |

Variables declared in the workflow or job `env` context are forwarded automatically.

## Outputs

| Name | Description |
|------|-------------|
| `job_name` | Resource name of the job |
| `job_status` | `succeeded`, `failed`, `timeout`, `cancelled` |
| `duration_seconds` | Job duration |
| `queue_duration_seconds` | Time until all PPU pods are scheduled |
| `occupied_ppu_card_hours` | PPU card-hours from pod scheduling until completion, including image pulling and startup |
| `execution_ppu_card_hours` | PPU card-hours while worker containers are running |
| `task_pods` | Comma-separated worker pod names |

The queue duration is measured from the first pod creation until every pod is scheduled. For a pod
that never schedules, it is measured until the job ends. Both card-hours metrics sum each
pod independently, so multi-node jobs are accounted for correctly.

## Repository layout

```
action.yml          Composite action definition
scripts/            Naming, submission, cleanup and dmesg scripts
infra/              ARC controller, runner scale sets, RBAC and etcd maintenance
```

See [infra/README.md](infra/README.md) for cluster setup.
