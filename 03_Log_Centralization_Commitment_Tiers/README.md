# Log Centralization, Commitment Tiers & Dedicated Clusters

## PowerShell Script: Get-WorkspaceIngestion.ps1

**Use this script first** to check if your workspaces meet the minimum 100GB/day ingestion requirement for dedicated clusters. Tracks total Log Analytics workspace ingestion across your environment for the last 30 days, **split by log classification** (Analytics, Basic, and Auxiliary), helping you understand data volumes per region before considering dedicated cluster deployment.

> **Important**: Dedicated clusters require a minimum commitment of 100GB/day. Only proceed with cluster creation if your regional ingestion meets this threshold.

> **Log Classifications**: The script automatically categorizes ingestion by table plan type (Analytics, Basic, Auxiliary) as defined in [Part 2: Log Classifications](../02_Log_Classifications/README.md). This breakdown helps you understand which log types contribute to your commitment tier calculations.

### Prerequisites

1. **Install required PowerShell modules**:
   ```powershell
   Install-Module Az.Accounts
   Install-Module Az.OperationalInsights
   ```
2. **Authenticate to Azure**: Run `Connect-AzAccount` or ensure you're already authenticated

### Usage

```powershell
git clone https://github.com/claestom/lawcostoptseries.git
cd lawcostoptseries/03_Log_Centralization_Commitment_Tiers/scripts
```

**Specify the region parameter** as dedicated clusters are region-specific and can only link workspaces within the same Azure region:

```powershell
.\Get-WorkspaceIngestion.ps1 -Region "eastus" [-SubscriptionsFile "subs.json"] [-IncludeZero] [-TenantId "tenant-id"]
```

**Optional parameters:**
- `-SubscriptionsFile`: Analyze only specific subscriptions (see format below)
- `-IncludeZero`: Include workspaces with zero data ingestion in results
- `-TenantId`: Specify a specific tenant ID for multi-tenant scenarios

### Parameters

- **IncludeZero**: Include workspaces with zero data ingestion in results
- **SubscriptionsFile**: Path to JSON file containing specific subscription IDs to analyze
- **Region**: Filter workspaces by specific Azure region
- **TenantId**: Specify a specific tenant ID for multi-tenant analysis

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

The script displays a detailed table showing:
- Workspace name and resource group
- Location (region)
- Subscription name
- **Analytics logs ingestion** (GB over last 30 days)
- **Basic logs ingestion** (GB over last 30 days)
- **Auxiliary logs ingestion** (GB over last 30 days)
- **Total ingestion** per workspace
- **Commitment tier recommendations** based on total ingestion volumes
- **Cost analysis** showing estimated pay-as-you-go costs vs. commitment tier savings

**Understanding Log Classifications:**
- **Analytics**: Standard logs with full query capabilities and retention (used for commitment tier calculations)
- **Basic**: Lower-cost logs with limited query capabilities, 8-day retention
- **Auxiliary**: Archive logs for compliance, lowest cost, minimal query access

The script provides both per-workspace breakdowns and aggregate totals across all analyzed workspaces, helping you understand which log types contribute most to your costs and commitment tier eligibility.

![Script Output Example](screenshots/workspace-ingestion-output.png)

### Expected Warnings

**Note**: The script may display authentication warnings caused by the `Get-AzSubscription` cmdlet when attempting to enumerate subscriptions. This is normal behavior when:

These warnings don't affect the script's functionality and can be safely ignored. The script will continue processing accessible tenants, subscriptions and workspaces.

### Use Case

This script is particularly valuable for:
- **Pre-deployment validation**: Confirming you have at least 100GB/day ingestion before creating dedicated clusters
- **Commitment tier planning**: Understanding actual data volumes before setting up dedicated clusters  
- **Regional analysis**: Identifying which regions have sufficient data volume to justify dedicated clusters
- **Cost optimization**: Determining if your workspaces meet the minimum requirements for commitment tier discounts
- **Log classification insights**: Understanding the breakdown between Analytics, Basic, and Auxiliary logs to optimize your table plan strategy (see [Part 2: Log Classifications](../02_Log_Classifications/README.md))
- **Multi-tier optimization**: Combining log classification changes (Part 2) with commitment tier pricing (Part 3) for maximum cost savings

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