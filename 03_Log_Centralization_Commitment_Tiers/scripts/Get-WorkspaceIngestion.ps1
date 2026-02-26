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
    
    # Find appropriate tier - select the highest tier that is at or below current ingestion
    # This ensures we recommend the lower tier when volume is between two tiers
    $recommendedTier = $null
    foreach ($tier in $commitmentTiers) {
        if ($tier.Capacity -le $avgAnalyticsPerDay) {
            $recommendedTier = $tier
        } else {
            break
        }
    }
    
    # If still null, use the minimum tier (100 GB/day)
    if (-not $recommendedTier) {
        $recommendedTier = $commitmentTiers[0]
    }
    
    Write-Host "Recommended Commitment Tier: $($recommendedTier.Capacity) GB/day" -ForegroundColor Cyan
} else {
    Write-Host "RECOMMENDATION: Use Pay-As-You-Go (PAYG) pricing" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Your average Analytics log ingestion: $avgAnalyticsPerDay GB/day" -ForegroundColor White
    Write-Host ""
    Write-Host "Dedicated clusters require a minimum commitment tier of 100 GB/day." -ForegroundColor Gray
    Write-Host "Your current Analytics log volume does not meet this threshold." -ForegroundColor Gray
    Write-Host "Pay-As-You-Go pricing is the most cost-effective option for your workload." -ForegroundColor Gray
}

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""