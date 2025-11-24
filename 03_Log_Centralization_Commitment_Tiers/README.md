# Log Centralization, Commitment Tiers & Dedicated Clusters

## PowerShell Script: Get-WorkspaceIngestion.ps1

**Use this script first** to check if your workspaces meet the minimum 100GB/day ingestion requirement for dedicated clusters. Tracks total Log Analytics workspace ingestion across your environment for the last 30 days, helping you understand data volumes per region before considering dedicated cluster deployment.

> **Important**: Dedicated clusters require a minimum commitment of 100GB/day. Only proceed with cluster creation if your regional ingestion meets this threshold.

### Prerequisites

1. **Install required PowerShell modules**:
   ```powershell
   Install-Module Az.Accounts
   Install-Module Az.OperationalInsights
   ```
2. **Authenticate to Azure**: Run `Connect-AzAccount` or ensure you're already authenticated

### Usage

#### Analyze all subscriptions in your tenant
```powershell
.\Get-WorkspaceIngestion.ps1
```

#### Analyze specific subscriptions using a JSON file
```powershell
.\Get-WorkspaceIngestion.ps1 -SubscriptionsFile "subs.json"
```

#### Filter by specific region
```powershell
.\Get-WorkspaceIngestion.ps1 -Region "eastus"
```

#### Include workspaces with zero ingestion
```powershell
.\Get-WorkspaceIngestion.ps1 -IncludeZero
```

### Parameters

- **IncludeZero**: Include workspaces with zero data ingestion in results
- **SubscriptionsFile**: Path to JSON file containing specific subscription IDs to analyze
- **Region**: Filter workspaces by specific Azure region

### Subscription Filter File Format

Create a `subs.json` file to analyze only specific subscriptions:

```json
{
  "scopes": [
    {"scope": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"},
    {"scope": "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
  ]
}
```

Replace the `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` with your actual subscription IDs.

### Output

The script displays a table showing:
- Workspace name and resource group
- Location (region)
- Subscription name
- Data ingested in GB over the last 30 days
- Total ingestion across all analyzed workspaces

![Script Output Example](screenshots/workspace-ingestion-output.png)

### Use Case

This script is particularly valuable for:
- **Pre-deployment validation**: Confirming you have at least 100GB/day ingestion before creating dedicated clusters
- **Commitment tier planning**: Understanding actual data volumes before setting up dedicated clusters  
- **Regional analysis**: Identifying which regions have sufficient data volume to justify dedicated clusters
- **Cost optimization**: Determining if your workspaces meet the minimum requirements for commitment tier discounts

## PowerShell Script: Create-ClusterAndLinkWorkspaces.ps1

**Use this script only after confirming minimum ingestion requirements with Get-WorkspaceIngestion.ps1**

Automates Azure Monitor Dedicated Cluster creation and workspace linking to achieve 15-36% cost savings through commitment tier pricing.

> **⚠️ Important**: Before using this script, review the [dedicated clusters preparation guide](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-dedicated-clusters?tabs=azure-portal#preparation) to understand planning requirements, capacity considerations, and deployment best practices.

### Prerequisites

1. **Clone this repository** and navigate to the script folder:
2. **Install Azure CLI** and run `az login`
3. **Tag your Log Analytics workspaces** with a key/value pair (e.g., `Environment=Production`)
4. **Ensure workspaces are in the same region** as your planned cluster
5. **Have Contributor permissions** on subscription and resource groups
6. **Verify minimum ingestion**: Run `Get-WorkspaceIngestion.ps1` first to confirm you have at least 100GB/day

### Usage

```powershell
git clone https://github.com/claestom/lawcostoptseries.git
cd lawcostoptseries/03_Log_Centralization_Commitment_Tiers/scripts
```

```powershell
.\Create-ClusterAndLinkWorkspaces.ps1 `
  -SubscriptionId "your-subscription-id" `
  -ResourceGroupName "your-resource-group" `
  -ClusterName "your-cluster-name" `
  -Region "westeurope" `
  -CommitmentTier 100 `
  -TagKey "Environment" `
  -TagValue "Production"
```

### Parameters

- **SubscriptionId**: Your Azure subscription ID
- **ResourceGroupName**: Resource group for the cluster
- **ClusterName**: Unique cluster name
- **Region**: Azure region (must match workspace locations)
- **CommitmentTier**: Daily GB commitment (minimum 100)
- **TagKey/TagValue**: Tag filter for workspace selection

### What It Does

1. Creates dedicated cluster with specified commitment tier
2. Waits for provisioning (up to 2.5 hours)
3. Finds workspaces matching region and tags
4. Links workspaces to cluster automatically that contain the required key/value tag pairs

### Troubleshooting

See [Azure Monitor dedicated clusters troubleshooting guide](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-dedicated-clusters?tabs=azure-portal#error-messages).