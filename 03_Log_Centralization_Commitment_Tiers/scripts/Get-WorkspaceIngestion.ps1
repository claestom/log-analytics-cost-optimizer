param(
    [switch]$IncludeZero,
    [string]$SubscriptionsFile,
    [string]$Region
)

# Check prerequisites
if (-not (Get-Module -ListAvailable Az.Accounts)) { Write-Error "Install Az.Accounts module"; return }
if (-not (Get-Module -ListAvailable Az.OperationalInsights)) { Write-Error "Install Az.OperationalInsights module"; return }

# Ensure authenticated
$context = Get-AzContext
if (-not $context) {
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}

# Get subscriptions to analyze
$subscriptions = @()

# Get subscriptions (suppress warnings with simple redirection)
if ($SubscriptionsFile) {
    $subJson = Get-Content $SubscriptionsFile | ConvertFrom-Json
    $requestedIds = $subJson.scopes | ForEach-Object { ($_.scope -split '/')[-1] }
    $subscriptions = $requestedIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ 2>$null 3>$null } | Where-Object { $_ }
} else {
    $subscriptions = Get-AzSubscription -TenantId $context.Tenant.Id 2>$null 3>$null
}

if (-not $subscriptions) { Write-Error "No accessible subscriptions found"; return }

# Date range and queries
$end = (Get-Date).ToUniversalTime()
$start = $end.AddDays(-30)
$startStr = $start.ToString('yyyy-MM-ddTHH:mm:ssZ')
$endStr = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')

$usageQuery = "Usage | where TimeGenerated >= datetime($startStr) and TimeGenerated < datetime($endStr) | summarize IngestionVolumeMB = sum(Quantity)"
$unionQuery = "union * | where TimeGenerated >= datetime($startStr) and TimeGenerated < datetime($endStr) | summarize TotalBytes = sum(_BilledSize)"

# Process workspaces and collect results
$results = @()
$total = 0

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $workspaces = Get-AzOperationalInsightsWorkspace 2>$null
    
    # Filter by region if specified
    if ($Region) {
        $workspaces = $workspaces | Where-Object { $_.Location -eq $Region }
    }
    
    foreach ($ws in $workspaces) {
        $gb = 0
        
        # Try Usage table, fallback to union
        try {
            $resp = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $usageQuery 2>$null
            if ($resp.Results[0].IngestionVolumeMB) {
                $gb = [math]::Round([double]$resp.Results[0].IngestionVolumeMB / 1024, 2)
            } else {
                $resp = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $unionQuery 2>$null
                if ($resp.Results[0].TotalBytes) {
                    $gb = [math]::Round([double]$resp.Results[0].TotalBytes / 1GB, 2)
                }
            }
        } catch { }
        
        if ($IncludeZero -or $gb -gt 0) {
            $total += $gb
            $results += [PSCustomObject]@{
                Workspace = $ws.Name
                ResourceGroup = $ws.ResourceGroupName
                Location = $ws.Location
                Subscription = $sub.Name
                'Ingested (GB)' = $gb
            }
        }
    }
}

# Display results in table format
if ($results) {
    $results | Format-Table -AutoSize
}

Write-Output "---"
Write-Output "Total: $total GB (Last 30 days)"
Write-Output "Average per day: $([math]::Round($total / 30, 2)) GB/day"