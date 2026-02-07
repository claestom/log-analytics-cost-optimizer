e# Data Ingestion Control & Transformations

Control and optimize Azure Monitor data ingestion through Data Collection Rules (DCRs) and KQL transformations to achieve 30-70% cost savings by filtering, sampling, and transforming data before storage.

## What's Included

- **PowerShell Scripts**: Automate DCR creation and management
- **KQL Queries**: Analyze ingestion patterns and identify optimization opportunities  
- **ARM/Bicep Templates**: Deploy DCRs using Infrastructure as Code
- **Implementation Guide**: Step-by-step transformation strategies

## Key Topics Covered

- **Data Collection Rules (DCRs)** for selective data collection
- **KQL transformations** to filter and modify data before ingestion
- **Sampling strategies** for high-volume data sources
- **Field reduction** to eliminate unnecessary columns
- **Performance optimization** for transformation efficiency

## Getting Started

1. **Analyze current ingestion**: Understand your data ingestion patterns
2. **Design transformations**: Create filtering and sampling rules
3. **Deploy DCRs**: Implement data collection rules
4. **Monitor impact**: Track cost savings

### Analyze Current Ingestion

Start with [Log Analytics Workspace Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-insights-overview#usage-tab) to get an understanding of data ingestion patterns in your workspace. The Usage tab provides valuable visualizations of data volume by table, solution, and data type. After this initial overview, use the provided KQL queries to dive deeper and identify high-volume, low-value data.

### Design Transformations

Use [Data Collection Transformations](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations) to filter, modify, or enrich data before it's stored in your Log Analytics workspace. Transformations are written in KQL and allow you to reduce data volume, remove sensitive information, or add calculated columns. Note that not all tables support transformations - check the [supported tables list](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations) to ensure your target tables are compatible.

### Deploy DCRs

Implement your transformations through [Data Collection Rules (DCRs)](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations). DCRs define how data is collected, transformed, and routed to your workspace. Use the provided ARM/Bicep templates or PowerShell scripts in this folder to deploy and manage your DCRs efficiently.

### Monitor Impact

After deploying your DCRs, return to [Log Analytics Workspace Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-insights-overview#usage-tab) to track the impact of your transformations. Monitor the Usage tab to verify ingestion reduction by table and calculate your cost savings over time.

## Real-World Example: Azure Firewall Selective Logging

One powerful example of data ingestion control is [optimizing Azure Firewall logs with selective logging](https://techcommunity.microsoft.com/blog/azurenetworksecurityblog/optimize-azure-firewall-logs-with-selective-logging/4438242). Azure Firewall can generate substantial log volumes, especially in environments with high network traffic. By using ingestion-time transformations, organizations can:

- **Filter out low-priority alerts**: Exclude IDPS signatures with low severity (e.g., `where Action !contains "alert" and Severity != 3`) to focus on actionable threats
- **Remove trusted network traffic**: Filter out logs from specific IP ranges like test or trusted networks (e.g., `where not(SourceIp startswith "10.0.200.")`) to eliminate unnecessary noise
- **Reduce column storage**: Use `project` statements to keep only the columns needed for security analysis

This approach can significantly reduce ingestion costs while maintaining the critical security telemetry needed for threat detection, compliance, and incident response. The same principles apply to other high-volume data sources in your workspace.

## Navigation

- [← Part 3: Log Centralization & Commitment Tiers](../03_Log_Centralization_Commitment_Tiers/)
- [↑ Series Overview](../)

## Implementation Guide

See [article.md](article.md) for comprehensive implementation strategies and examples.