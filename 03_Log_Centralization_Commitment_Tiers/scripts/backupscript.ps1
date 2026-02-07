# Creates Azure Monitor Dedicated Cluster and links workspaces with matching tags
#
# DESCRIPTION:
#   1. Creates a new Azure Monitor Dedicated Cluster (or uses existing one)
#   2. Waits for cluster provisioning to complete (up to 2.5 hours)
#   3. Finds all Log Analytics workspaces in the same region with matching tag key/value
#   4. Links found workspaces to the dedicated cluster for cost optimization
#
# PREREQUISITES:
#   - Azure CLI installed and logged in (run 'az login')
#   - Contributor permissions on subscription and resource group
#   - Log Analytics workspaces must be tagged with the specified key/value pair
#   - Minimum commitment tier is 100GB/day
#
# PARAMETERS:
#   SubscriptionId    - Your Azure subscription GUID
#   ResourceGroupName - Resource group where cluster will be created
#   ClusterName       - Unique name for the dedicated cluster
#   Region           - Azure region (must match workspace locations)
#   CommitmentTier   - Daily data ingestion commitment in GB (100, 200, 300, etc.)
#   TagKey           - Tag key to filter workspaces (e.g., "Environment")
#   TagValue         - Tag value to match (e.g., "Production")
#
# EXAMPLES:
#   # Link all Production workspaces in East US with 500GB/day commitment
#   .\Create-ClusterAndLinkWorkspaces.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -ResourceGroupName "rg-monitoring" -ClusterName "cluster-prod-eastus" -Region "eastus" -CommitmentTier 500 -TagKey "Environment" -TagValue "Production"
#
#   # Link all workspaces tagged with Department=Finance in West Europe
#   .\Create-ClusterAndLinkWorkspaces.ps1 -SubscriptionId "87654321-4321-4321-4321-210987654321" -ResourceGroupName "rg-finance" -ClusterName "cluster-finance" -Region "westeurope" -CommitmentTier 100 -TagKey "Department" -TagValue "Finance"

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,
    
    [Parameter(Mandatory = $true)]
    [string]$Region,
    
    [Parameter(Mandatory = $true)]
    [int]$CommitmentTier,
    
    [Parameter(Mandatory = $true)]
    [string]$TagKey,
    
    [Parameter(Mandatory = $true)]
    [string]$TagValue
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Wait-ClusterProvisioned {
    param([string]$ClusterUri, [hashtable]$Headers)
    
    Write-Log "Waiting for cluster provisioning (up to 2 hours)..."
    $maxWait = (Get-Date).AddHours(2.5)
    
    while ((Get-Date) -lt $maxWait) {
        Start-Sleep -Seconds 300  # Check every 5 minutes
        
        try {
            $cluster = Invoke-RestMethod -Uri $ClusterUri -Method GET -Headers $Headers
            $status = $cluster.properties.provisioningState
            Write-Log "Cluster status: $status"
            
            if ($status -eq "Succeeded") {
                Write-Log "Cluster provisioning completed!"
                return $cluster
            }
            elseif ($status -eq "Failed") {
                throw "Cluster provisioning failed"
            }
        }
        catch {
            Write-Log "Error checking status: $($_.Exception.Message)" "WARNING"
        }
    }
    throw "Cluster provisioning timeout"
}

function Get-WorkspacesToLink {
    param([string]$SubscriptionId, [string]$Region, [string]$TagKey, [string]$TagValue, [hashtable]$Headers)
    
    Write-Log "Finding workspaces in $Region with tag $TagKey=$TagValue"
    $workspacesUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.OperationalInsights/workspaces?api-version=2023-09-01"
    $workspaces = Invoke-RestMethod -Uri $workspacesUri -Method GET -Headers $Headers
    
    $filteredWorkspaces = @()
    foreach ($workspace in $workspaces.value) {
        if ($workspace.location -eq $Region -and $workspace.tags.$TagKey -eq $TagValue) {
            $filteredWorkspaces += $workspace
            Write-Log "Found workspace: $($workspace.name)"
        }
    }
    return $filteredWorkspaces
}

function Connect-WorkspaceToCluster {
    param([object]$Workspace, [string]$ClusterResourceId)
    
    $workspaceName = $workspace.name
    $workspaceRG = $workspace.id.Split('/')[4]
    $workspaceSubscription = $workspace.id.Split('/')[2]
    
    Write-Log "Linking workspace: $workspaceName"
    
    # Set workspace subscription context
    az account set --subscription $workspaceSubscription
    
    # Link workspace using Azure CLI as per Microsoft docs
    $result = az monitor log-analytics workspace linked-service create --no-wait --name cluster --resource-group $workspaceRG --workspace-name $workspaceName --write-access-resource-id $ClusterResourceId 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Successfully linked workspace: $workspaceName"
        return $true
    } else {
        Write-Log "Failed to link workspace: $workspaceName - $result" "ERROR"
        return $false
    }
}

try {
    Write-Log "Azure Monitor Dedicated Cluster Creation and Workspace Linking"
    
    # Check Azure CLI authentication
    $currentAccount = az account show 2>$null | ConvertFrom-Json
    if (-not $currentAccount) {
        throw "Not logged into Azure CLI. Please run 'az login' first."
    }
    Write-Log "Authenticated as: $($currentAccount.user.name)"
    
    # Set subscription context
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set subscription context."
    }
    
    # Get access token
    $tokenResult = az account get-access-token --resource https://management.azure.com/ 2>$null | ConvertFrom-Json
    if (-not $tokenResult -or -not $tokenResult.accessToken) {
        throw "Failed to obtain access token."
    }
    
    $headers = @{
        "Authorization" = "Bearer $($tokenResult.accessToken)"
        "Content-Type" = "application/json"
    }
    
    $clusterUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/clusters/$ClusterName" + "?api-version=2023-09-01"
    
    # Check if cluster exists
    $cluster = $null
    try {
        $cluster = Invoke-RestMethod -Uri $clusterUri -Method GET -Headers $headers
        Write-Log "Cluster already exists: $($cluster.properties.provisioningState)"
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            # Create cluster using the same logic as backupscript.ps1
            Write-Log "Creating cluster: $ClusterName"
            
            $requestBody = @{
                identity = @{
                    type = "systemAssigned"
                }
                sku = @{
                    name = "capacityReservation"
                    Capacity = $CommitmentTier
                }
                properties = @{
                    billingType = "Cluster"
                }
                location = $Region
            }
            
            $jsonBody = $requestBody | ConvertTo-Json -Depth 3
            $cluster = Invoke-RestMethod -Uri $clusterUri -Method PUT -Headers $headers -Body $jsonBody
            Write-Log "Cluster creation request sent. Status: $($cluster.properties.provisioningState)"
        } else {
            throw
        }
    }
    
    # Wait for cluster to be provisioned if not already succeeded
    if ($cluster.properties.provisioningState -ne "Succeeded") {
        $cluster = Wait-ClusterProvisioned -ClusterUri $clusterUri -Headers $headers
    }
    
    Write-Log "Cluster ready. ID: $($cluster.id)"
    
    # Find and link workspaces
    $workspaces = Get-WorkspacesToLink -SubscriptionId $SubscriptionId -Region $Region -TagKey $TagKey -TagValue $TagValue -Headers $headers
    
    if ($workspaces.Count -eq 0) {
        Write-Log "No workspaces found with matching criteria" "WARNING"
    } else {
        Write-Log "Found $($workspaces.Count) workspaces to link"
        
        $successCount = 0
        foreach ($workspace in $workspaces) {
            if (Connect-WorkspaceToCluster -Workspace $workspace -ClusterResourceId $cluster.id) {
                $successCount++
            }
        }
        
        Write-Log "Linked $successCount of $($workspaces.Count) workspaces successfully"
    }
    
    Write-Log "Process completed successfully!"
}
catch {
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    exit 1
}
