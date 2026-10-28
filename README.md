# k8s-image-check

A single bash script that checks every Deployment and StatefulSet on a Kubernetes cluster (built and tested for RKE2) and tells you what's out of date.

- Checks **every container image** in each workload against its registry and finds the newest release of the same tag shape
- Detects **Helm-deployed apps**, compares the deployed **chart version** with the latest published one, and tells you which apps need `helm upgrade` rather than an image bump
- Groups results by namespace, with colour-coded status for each image and release
- Outputs a readable terminal report, or JSON with `-j`

## Requirements

- bash 4+
- `kubectl` (with access to the cluster)
- `jq`
- `curl`

No Helm CLI is needed. If `KUBECONFIG` isn't set, the script uses `/etc/rancher/rke2/rke2.yaml` when it's readable.

## Usage

```bash
chmod +x k8s-image-check.sh

./k8s-image-check.sh                  # all namespaces
./k8s-image-check.sh -s -u            # skip system namespaces, only show things that need updating
./k8s-image-check.sh -n my-namespace  # a single namespace
./k8s-image-check.sh -d -i            # include DaemonSets and init containers
./k8s-image-check.sh -j | jq          # JSON output
./k8s-image-check.sh --no-helm        # images only, skip Helm checks
```

### Options

| Option | Description |
|---|---|
| `-n`, `--namespace NS` | Check one namespace only |
| `-s`, `--skip-system` | Skip system namespaces (`kube-system`, `cattle-*`, `fleet-*`, etc.) |
| `-d`, `--daemonsets` | Include DaemonSets |
| `-i`, `--init` | Include init containers |
| `-u`, `--updates-only` | Only show workloads with an image update, or in a release with a chart update |
| `-j`, `--json` | JSON output instead of the visual report |
| `-p`, `--max-pages N` | Max registry tag pages to read per repo (default 100) |
| `-k`, `--kubeconfig FILE` | Kubeconfig to use |
| `-c`, `--context NAME` | Kubeconfig context to use |
| `--no-helm` | Skip Helm release and chart checks |
| `--no-color` | Plain output |
| `-h`, `--help` | Show usage |

## Reading the report

| Symbol | Meaning |
|---|---|
| ✔ green | Up to date |
| ⬆ yellow | Patch or minor update available |
| ⚠ red | Major update available |
| ● blue | Floating tag (`latest`, `stable`, a custom name) or digest, so nothing to compare |
| ? magenta | Couldn't query the registry, or no comparable tags |

Helm-managed workloads appear under a `⎈ HELM` header showing the release, `chart current → latest`, the app version change and the chart repo. Images behind inside a release are marked:

- `(via helm upgrade)` when the chart itself is outdated, so upgrade the chart rather than the image
- `(pinned in chart values)` when the chart is current but the image tag was overridden, so change the values

A table of releases needing `helm upgrade` is printed before the summary.

## How it works

- **Images:** one `kubectl get` call, then each image's registry is queried through the OCI `/v2/<repo>/tags/list` API with anonymous token auth and pagination. Quay uses its own API, which returns the newest tags first. Only tags of the same shape as yours are compared (`1.25.3-alpine` is compared with other `X.Y.Z-alpine` tags).
- **Helm releases:** read from Helm's release secrets (`sh.helm.release.v1.*`), which give the top-level chart even for sub-chart workloads. If no release secret exists, the `helm.sh/chart` label is used.
- **Latest chart:** looked up on [Artifact Hub](https://artifacthub.io/), using the repo that actually contains your deployed chart version. If none does, the closest match is shown with a `~` to mark it unverified.

## Limitations

- Private registries that need credentials show as "lookup failed".
- Digest-only references (`image@sha256:...`) can't be compared.
- Charts not on Artifact Hub show as "latest chart not found".
- Reading release secrets needs permission to read Secrets in the relevant namespaces. Without it, the script falls back to workload labels.
- "Major", "minor" and "patch" are based on version numbers only. Read the release notes before upgrading.
- The script reports only. It doesn't change anything on the cluster.

## License

<!-- TODO: add a license -->
