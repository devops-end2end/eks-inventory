# EKS Inventory & Tag Reconciliation

`eks-inventory` is a CLI toolkit for auditing Kubernetes workloads across EKS clusters, resolving resource ownership (ArgoCD vs. Terraform Cloud vs. EKS-managed), verifying container image availability, and automating `team` label reconciliation via Pull Requests for cost attribution and operational observability.

---

## Architecture & Workflow

The toolkit operates across three primary workflows:

1. **Cluster Inventory (`inventory-all.sh` / `scripts/inventory.sh`)**:
   * Queries target EKS clusters via `kubectl` for standard workloads (`Deployments`, `StatefulSets`, `DaemonSets`, `Services`, `Ingresses`, `CronJobs`, `HPAs`) and detected CRDs (`HTTPRoutes`, `CronWorkflows`, `WorkflowTemplates`, `ExternalSecrets`, Argo Events, `VPAs`).
   * Cross-references resources against **ArgoCD** application states and **Terraform Cloud (TFC)** state files to determine true ownership (`argocd`, `terraform`, `both`, `eks-managed`, `eks-bootstrap`, or `none`).
   * Outputs per-cluster CSVs and merges them into `output/all/inventory.csv`.

2. **Team Label Reconciliation (`scripts/label.sh`)**:
   * **Phase 1 (Report)**: Scans inventory CSVs for resources missing a `team` label and generates `needs-team.csv`.
   * **Phase 2 (Apply)**: Reads a populated `needs-team.csv`, modifies Kustomize overlays (using `labels` with `includeSelectors: false` to avoid immutable selector errors) and Terraform HCL (`web_identities_k8s` service accounts), and automatically opens Bitbucket Pull Requests against `cd-deploy-configs` and `eks_infrastructure`.

3. **Image Availability Audit (`scripts/check-images.sh`)**:
   * Filters ArgoCD-managed Deployments from the merged inventory (optionally filtering by stale sync age via `--days N`).
   * Inspects active container images using `docker manifest inspect` to flag missing or unpullable images in `output/all/image-check.csv`.

---

## Directory Structure

```text
eks-inventory/
├── config/
│   └── prod-ric1.env           # Per-cluster environment and TFC/ArgoCD mappings
├── inventory-all.sh            # Orchestrates inventory across all config/*.env files
├── output/
│   ├── all/
│   │   ├── image-check.csv     # Merged container image audit results
│   │   ├── inventory.csv       # Merged multi-cluster resource inventory
│   │   └── needs-team.csv      # Merged report of resources missing team labels
│   └── prod-ric1/
│       └── inventory.csv       # Single-cluster inventory output
└── scripts/
    ├── check-images.sh         # Verifies image pullability for ArgoCD deployments
    ├── inventory.sh            # Single-cluster inventory & ownership resolution
    ├── label.sh                # Two-phase team label reporting and PR automation
    └── lib/
        ├── apply_labels.py     # Modifies Kustomize YAMLs & Terraform HCL files
        ├── bitbucket-pr.sh     # Bitbucket Cloud API wrapper for branches/commits/PRs
        ├── resolve_ownership.py# Joins K8s, ArgoCD, and TFC state data
        └── tfc_client.py       # Fetches and caches Terraform Cloud state
```

---

## Prerequisites

* **CLI Tools**: `bash` (4.0+), `python3` (3.8+), `kubectl`, `git`, `curl`, and `docker` (required for `check-images.sh`).
* **Cluster Access**: Valid `kubeconfig` contexts for both target EKS clusters and the hosting ArgoCD clusters.
* **Local Repositories (for `label.sh --apply`)**:
  The target Git repositories must be cloned as sibling directories to `eks-inventory`:
  ```text
  workspace/
  ├── eks-inventory/
  ├── cd-deploy-configs/
  └── eks_infrastructure/
  ```
* **Environment Variables**:
  * `TFC_TOKEN`: Terraform Cloud API token.
  * `TFC_ORG`: Terraform Cloud organization name.
  * `BB_API_TOKEN`: Bitbucket Cloud personal access token (required for opening PRs).
  * `BB_WORKSPACE`: *(Optional)* Bitbucket workspace (defaults to `admarketplace`).
  * `TF_REPO_SLUG`: *(Optional)* Bitbucket repo slug for Terraform (defaults to `eks-infrastructure`).

---

## Configuration

Each cluster requires a `.env` file in `config/` (e.g., `config/prod-ric1.env`):

```bash
ENV="prod"
REGION="ric1"
KUBE_CONTEXT="eks-prod-ric1-01"

# ArgoCD Host Details
ARGOCD_CONTEXT="prod-argocd-context"
ARGOCD_NAMESPACE="argocd"
# OLD_CLUSTER_URL="https://..." # Optional override if cluster secret lookup differs

# Terraform Cloud Details
TFC_WORKSPACE="eks-prod-ric1-01"
TFC_MODULE="module.eks_prod_ric1_01"
```

---

## Usage

### 1. Run Cluster Inventory

**All configured clusters (recommended):**
```bash
./inventory-all.sh
```
*Generates `output/<env>-<region>/inventory.csv` for each cluster and merges them into `output/all/inventory.csv`.*

**Single cluster:**
```bash
./scripts/inventory.sh config/prod-ric1.env
```

---

### 2. Reconcile Missing `team` Labels

#### Phase 1: Generate Unlabeled Resource Report
```bash
# Across all inventoried clusters
./scripts/label.sh --all

# Or for a single cluster
./scripts/label.sh config/prod-ric1.env
```
This outputs `output/all/needs-team.csv` (or `output/<env>-<region>/needs-team.csv`).

#### Phase 2: Populate & Apply Labels via Pull Request
Open the generated `needs-team.csv` and fill in the `team` column for the resources you wish to update. Leave rows blank to skip them.

```bash
# Apply changes across all clusters using output/all/needs-team.csv
./scripts/label.sh --all --apply

# Apply changes for a single cluster
./scripts/label.sh config/prod-ric1.env --apply output/prod-ric1/needs-team.csv
```

**Optional Flags for `--apply`:**
* `--teams team-a,team-b`: Only process rows matching specific team names.
* `--limit N`: Cap the number of ArgoCD apps modified per run (useful for batching PRs; already-labeled apps are automatically skipped).
* `--tag custom-suffix`: Append a custom identifier to the generated Git branch name.
* `--clusters prod-ric1,stg-use1`: Restrict `--all --apply` to specific `env-region` targets.

> **Note on Terraform & Manual Reviews:**
> * `kubernetes_service_account_v1` resources managed by `web_identities_k8s` are updated automatically in HCL.
> * `helm_release` resources and unmanaged (`ownership_source=none`) resources are listed in the generated PR description under **Requires manual changes**.

---

### 3. Audit Container Images

Verify that container images running in ArgoCD-managed Deployments are still pullable from their registries:

```bash
# Check all ArgoCD-managed Deployments
./scripts/check-images.sh

# Check only Deployments whose ArgoCD app hasn't synced in > 60 days
./scripts/check-images.sh --days 60
```
Results are written to `output/all/image-check.csv`, sorted with `missing` images at the top.

---

## Inventory Schema (`inventory.csv`)

| Column | Description |
| :--- | :--- |
| `cluster`, `env`, `region` | Cluster context name, environment (`dev`, `stg`, `prod`), and AWS region. |
| `namespace`, `resource_type`, `resource_name` | Kubernetes resource identifiers. |
| `argocd_app`, `argocd_sync_status`, `argocd_health_status` | Matched ArgoCD Application name and current status. |
| `argocd_last_sync`, `argocd_days_since_sync`, `argocd_source_path` | Timestamp of last sync, days elapsed, and Git path to manifests. |
| `tfc_workspace`, `tfc_module`, `tfc_resource_type` | Matched Terraform Cloud workspace, module path, and resource type. |
| `team_label` | Current value of the `team` metadata label on the resource. |
| `ownership_source` | Resolved owner: `argocd`, `terraform`, `both`, `eks-managed`, `eks-bootstrap`, or `none`. |
| `migration_candidate` | Indicates whether the resource is eligible for automated GitOps/Kustomize updates (`yes`, `skip`, `manual-review`). |
```

Let me know if you'd like to add any specific details about `scripts/creds.sh`, team naming conventions, or CI/CD scheduling!