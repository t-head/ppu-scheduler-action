# PPU Distributed Action — 集群基础设施配置

本目录包含 ARC (Actions Runner Controller) 在 K8s 集群中的完整配置。

## 前置条件

- Kubernetes 集群
- Helm 3
- PPU 节点已标记 `board-type=ZW-M890P` 或 `board-type=OAM-810E`
- CPU 节点已标记 `server-type=cpu`

## 部署顺序

1. **创建 Namespace**
   ```bash
   kubectl create namespace arc-systems
   kubectl create namespace arc-runners
   ```

2. **安装 ARC Controller** — 见 `arc-controller/install.sh`

3. **创建 RBAC 资源**
   ```bash
   kubectl apply -f infra/rbac/serviceaccount.yaml
   kubectl apply -f infra/rbac/clusterrole.yaml
   kubectl apply -f infra/rbac/clusterrolebinding.yaml
   ```

4. **创建 Secrets** — 见 `secrets/README.md`

5. **创建 ConfigMap**
   ```bash
   kubectl apply -f infra/configmaps/hook-extension-cpu.yaml
   ```

6. **安装 Runner Scale Sets**
   ```bash
   # 基础 Runner (flytiger-eco)
   helm install k8s-runner \
     oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
     -n arc-runners -f infra/runners/values-runner-base.yaml

   # CPU Runner (flytiger-eco)
   helm install k8s-runner-cpu-flytiger \
     oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
     -n arc-runners -f infra/runners/values-cpu-flytiger.yaml
   ```
