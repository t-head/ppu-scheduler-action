# GitHub App Secrets

Secrets 包含 GitHub App 凭证，不纳入版本控制。需手动创建：

## flytiger-eco 组织

```bash
kubectl create secret generic arc-github-app-secret -n arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<T_HEAD_INSTALLATION_ID> \
  --from-literal=github_app_private_key="$(cat /path/to/private-key.pem)"
```

## flytiger-eco 组织

```bash
kubectl create secret generic arc-github-app-secret-flytiger -n arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<FLYTIGER_INSTALLATION_ID> \
  --from-literal=github_app_private_key="$(cat /path/to/private-key.pem)"
```

## 新增组织

如需为其它组织部署 Runner，创建对应的 Secret：

```bash
kubectl create secret generic arc-github-app-secret-<org-name> -n arc-runners \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<ORG_INSTALLATION_ID> \
  --from-literal=github_app_private_key="$(cat /path/to/private-key.pem)"
```
