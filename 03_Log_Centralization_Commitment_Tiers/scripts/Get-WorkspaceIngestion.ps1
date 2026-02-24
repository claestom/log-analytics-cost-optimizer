param(
    [switch]$IncludeZero,
    [string]$SubscriptionsFile,
    [string]$Region,
    [string]$TenantId
)

# Commitment tier definitions (GB/day and monthly cost in USD)
$commitmentTiers = @(
    @{ Capacity = 100; MonthlyCost = 6570; DailyCost = 219 }
    @{ Capacity = 200; MonthlyCost = 11820; DailyCost = 394 }
    @{ Capacity = 300; MonthlyCost = 17070; DailyCost = 569 }
    @{ Capacity = 400; MonthlyCost = 22320; DailyCost = 744 }
    @{ Capacity = 500; MonthlyCost = 27540; DailyCost = 918 }
    @{ Capacity = 1000; MonthlyCost = 55080; DailyCost = 1836 }
    @{ Capacity = 2000; MonthlyCost = 110160; DailyCost = 3672 }
    @{ Capacity = 5000; MonthlyCost = 275400; DailyCost = 9180 }
)

# Check prerequisites
if (-not (Get-Module -ListAvailable Az.Accounts)) { Write-Error "Install Az.Accounts module"; return }
if (-not (Get-Module -ListAvailable Az.OperationalInsights)) { Write-Error "Install Az.OperationalInsights module"; return }

# Ensure authenticated
$context = Get-AzContext
if (-not $context) {
    if ($TenantId) {
        Connect-AzAccount -TenantId $TenantId | Out-Null
    } else {
        Connect-AzAccount | Out-Null
    }
    $context = Get-AzContext
}

# Use provided TenantId or context tenant
$targetTenantId = if ($TenantId) { $TenantId } else { $context.Tenant.Id }

# Get subscriptions to analyze
$subscriptions = @()

# Get subscriptions (suppress warnings with simple redirection)
if ($SubscriptionsFile) {
    $subJson = Get-Content $SubscriptionsFile | ConvertFrom-Json
    $requestedIds = $subJson.scopes | ForEach-Object { ($_.scope -split '/')[-1] }
    $subscriptions = $requestedIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ -TenantId $targetTenantId 2>$null 3>$null } | Where-Object { $_ }
} else {
    $subscriptions = Get-AzSubscription -TenantId $targetTenantId 2>$null 3>$null
}

if (-not $subscriptions) { Write-Error "No accessible subscriptions found"; return }

Write-Host "Found $($subscriptions.Count) subscription(s) to analyze" -ForegroundColor Cyan
$subscriptions | ForEach-Object { Write-Host "  - $($_.Name) ($($_.Id))" -ForegroundColor Gray }
Write-Host ""

# Date range and queries
$end = (Get-Date).ToUniversalTime()
$start = $end.AddDays(-30)
$startStr = $start.ToString('yyyy-MM-ddTHH:mm:ssZ')
$endStr = $end.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Query to get ingestion by data type
$usageByTypeQuery = @"
Usage 
| where TimeGenerated >= datetime($startStr) and TimeGenerated < datetime($endStr)
| where IsBillable == true
| summarize IngestionVolumeMB = sum(Quantity) by DataType
"@

# Process workspaces and collect results
$workspaceResults = @()
$totalAnalytics = 0
$totalBasic = 0
$totalAuxiliary = 0

foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name)..." -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id -TenantId $targetTenantId | Out-Null
    $workspaces = Get-AzOperationalInsightsWorkspace 2>$null
    
    if (-not $workspaces) {
        Write-Host "  No workspaces found" -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  Found $($workspaces.Count) workspace(s)" -ForegroundColor Gray
    
    # Filter by region if specified
    if ($Region) {
        $workspaces = $workspaces | Where-Object { $_.Location -eq $Region }
        Write-Host "  Filtered to $($workspaces.Count) workspace(s) in region: $Region" -ForegroundColor Gray
    }
    
    foreach ($ws in $workspaces) {
        Write-Host "    Analyzing: $($ws.Name)..." -ForegroundColor Gray
        
        # Initialize workspace ingestion tracking
        $wsAnalytics = 0
        $wsBasic = 0
        $wsAuxiliary = 0
        
        try {
            # Get all tables with their plans
            Write-Host "      Retrieving table configurations..." -ForegroundColor DarkGray
            $tables = Get-AzOperationalInsightsTable -ResourceGroupName $ws.ResourceGroupName -WorkspaceName $ws.Name -ErrorAction SilentlyContinue
            $tablePlanMap = @{}
            
            foreach ($table in $tables) {
                $plan = if ($table.Plan) { $table.Plan } else { "Analytics" } # Default to Analytics if not specified
                $tablePlanMap[$table.Name] = $plan
            }
            
            Write-Host "      Found $($tables.Count) tables" -ForegroundColor DarkGray
            
            # Query ingestion by data type
            Write-Host "      Querying ingestion data..." -ForegroundColor DarkGray
            $resp = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.CustomerId -Query $usageByTypeQuery -ErrorAction Stop
            
            if ($resp.Results) {
                foreach ($row in $resp.Results) {
                    $dataType = $row.DataType
                    $ingestionMB = [double]$row.IngestionVolumeMB
                    $ingestionGB = [math]::Round($ingestionMB / 1024, 2)
                    
                    # Determine which plan this table uses
                    $plan = if ($tablePlanMap.ContainsKey($dataType)) { 
                        $tablePlanMap[$dataType] 
                    } else { 
                        "Analytics" # Default if table not found
                    }
                    
                    # Aggregate by plan type
                    switch ($plan) {
                        "Analytics" { $wsAnalytics += $ingestionGB }
                        "Basic" { $wsBasic += $ingestionGB }
                        "Auxiliary" { $wsAuxiliary += $ingestionGB }
                        default { $wsAnalytics += $ingestionGB }
                    }
                }
            }
            
            $wsTotal = $wsAnalytics + $wsBasic + $wsAuxiliary
            
            Write-Host "      Analytics: $wsAnalytics GB | Basic: $wsBasic GB | Auxiliary: $wsAuxiliary GB" -ForegroundColor Green
            
            if ($IncludeZero -or $wsTotal -gt 0) {
                $totalAnalytics += $wsAnalytics
                $totalBasic += $wsBasic
                $totalAuxiliary += $wsAuxiliary
                
                $workspaceResults += [PSCustomObject]@{
                    Workspace = $ws.Name
                    ResourceGroup = $ws.ResourceGroupName
                    Location = $ws.Location
                    Subscription = $sub.Name
                    'Analytics (GB)' = $wsAnalytics
                    'Basic (GB)' = $wsBasic
                    'Auxiliary (GB)' = $wsAuxiliary
                    'Total (GB)' = $wsTotal
                }
            }
            
        } catch {
            Write-Host "      ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  WORKSPACE INGESTION DETAILS (Last 30 Days)" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# Display results in table format
if ($workspaceResults) {
    $workspaceResults | Format-Table -AutoSize
} else {
    Write-Host "No workspaces with data found" -ForegroundColor Yellow
}

# Calculate totals
$grandTotal = $totalAnalytics + $totalBasic + $totalAuxiliary
$avgAnalyticsPerDay = [math]::Round($totalAnalytics / 30, 2)
$avgBasicPerDay = [math]::Round($totalBasic / 30, 2)
$avgAuxiliaryPerDay = [math]::Round($totalAuxiliary / 30, 2)
$avgTotalPerDay = [math]::Round($grandTotal / 30, 2)

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  SUMMARY BY LOG CLASSIFICATION" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Analytics Logs:  $totalAnalytics GB (Last 30 days) | Avg: $avgAnalyticsPerDay GB/day" -ForegroundColor Yellow
Write-Host "Basic Logs:      $totalBasic GB (Last 30 days) | Avg: $avgBasicPerDay GB/day" -ForegroundColor Yellow
Write-Host "Auxiliary Logs:  $totalAuxiliary GB (Last 30 days) | Avg: $avgAuxiliaryPerDay GB/day" -ForegroundColor Yellow
Write-Host "---"
Write-Host "TOTAL:           $grandTotal GB (Last 30 days) | Avg: $avgTotalPerDay GB/day" -ForegroundColor Green
Write-Host ""

# Commitment Tier Recommendations
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  COMMITMENT TIER ANALYSIS" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

if ($avgAnalyticsPerDay -ge 100) {
    Write-Host "RECOMMENDATION: Consider a Dedicated Log Analytics Cluster with Commitment Tier" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your average Analytics log ingestion: $avgAnalyticsPerDay GB/day" -ForegroundColor White
    Write-Host ""
    
    # Find appropriate tier
    $recommendedTier = $null
    foreach ($tier in $commitmentTiers) {
        if ($avgAnalyticsPerDay -le $tier.Capacity) {
            $recommendedTier = $tier
            break
        }
    }
    
    if (-not $recommendedTier) {
        $recommendedTier = $commitmentTiers[-1] # Largest tier
    }
    
    # Calculate pay-as-you-go cost for comparison (assuming $2.30/GB for Analytics logs)
    $payAsYouGoCost = [math]::Round($avgAnalyticsPerDay * 2.30 * 30, 2)
    $commitmentMonthlyCost = $recommendedTier.MonthlyCost
    $savings = [math]::Round($payAsYouGoCost - $commitmentMonthlyCost, 2)
    $savingsPercent = [math]::Round(($savings / $payAsYouGoCost) * 100, 2)
    
    Write-Host "Recommended Commitment Tier: $($recommendedTier.Capacity) GB/day" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Cost Comparison (Monthly):" -ForegroundColor White
    Write-Host "  Pay-as-you-go (estimated):     `$$payAsYouGoCost" -ForegroundColor Gray
    Write-Host "  Commitment Tier:               `$$commitmentMonthlyCost" -ForegroundColor Gray
    if ($savings -gt 0) {
        Write-Host "  Monthly Savings:               `$$savings ($savingsPercent%)" -ForegroundColor Green
    } else {
        Write-Host "  Monthly Additional Cost:       `$$([math]::Abs($savings))" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Benefits of Dedicated Cluster:" -ForegroundColor White
    Write-Host "  • Centralized log management across multiple workspaces" -ForegroundColor Gray
    Write-Host "  • Cross-workspace queries without additional cost" -ForegroundColor Gray
    Write-Host "  • Customer-managed keys (CMK) for encryption" -ForegroundColor Gray
    Write-Host "  • Availability Zones support" -ForegroundColor Gray
    Write-Host "  • Commitment tier pricing for predictable costs" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor White
    Write-Host "  1. Review the workspace list to determine which should be linked to the cluster" -ForegroundColor Gray
    Write-Host "  2. Create a dedicated cluster in your preferred region" -ForegroundColor Gray
    Write-Host "  3. Link workspaces to the cluster to benefit from centralized billing" -ForegroundColor Gray
    Write-Host "  4. Monitor ingestion patterns and adjust commitment tier as needed" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Documentation: https://azure.microsoft.com/en-us/pricing/details/monitor/" -ForegroundColor DarkCyan
    
} elseif ($avgAnalyticsPerDay -ge 50) {
    Write-Host "NOTE: You're approaching commitment tier threshold" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Current Analytics ingestion: $avgAnalyticsPerDay GB/day" -ForegroundColor White
    Write-Host "Commitment tiers start at 100 GB/day" -ForegroundColor White
    Write-Host ""
    Write-Host "Consider monitoring your ingestion growth. A dedicated cluster becomes" -ForegroundColor Gray
    Write-Host "cost-effective at ~100 GB/day of Analytics logs." -ForegroundColor Gray
} else {
    Write-Host "Current Analytics ingestion: $avgAnalyticsPerDay GB/day" -ForegroundColor White
    Write-Host ""
    Write-Host "Your ingestion volume is below commitment tier thresholds." -ForegroundColor Gray
    Write-Host "Pay-as-you-go pricing is likely more cost-effective for your workload." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Commitment tiers start at 100 GB/day and are beneficial for:" -ForegroundColor Gray
    Write-Host "  • High-volume analytics log ingestion" -ForegroundColor Gray
    Write-Host "  • Multiple workspaces that need centralized management" -ForegroundColor Gray
    Write-Host "  • Requirements for customer-managed keys or availability zones" -ForegroundColor Gray
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""