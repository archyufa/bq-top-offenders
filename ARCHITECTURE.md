# Architecture Document: BigQuery Real-Time Cost Optimization and Monitoring

## 1. Introduction

This document outlines the architecture for a comprehensive solution to proactively control, monitor, and alert on Google BigQuery costs in near real-time. The primary business objectives are to prevent accidental high charges, provide immediate visibility into spending patterns, and enable a rapid response to cost anomalies.

The standard Google Cloud Billing console and billing export to BigQuery are designed for financial accuracy and have inherent delays (up to 24 hours), making them unsuitable for immediate operational alerting. This architecture addresses that gap by leveraging the Google Cloud Operations Suite to create a "fast path" for cost data.

## 2. Guiding Principles

*   **Proactive Control over Reactive Shock:** The first line of defense should be mechanisms that prevent cost overruns before they happen.
*   **Real-Time Visibility:** The system must provide visibility into query costs within minutes, not hours, of query execution.
*   **Automated Alerting:** Key personnel should be automatically notified of significant cost events without needing to constantly watch a dashboard.
*   **Actionable Insights:** The monitoring and alerting tools must provide enough detail to quickly diagnose the root cause of a cost spike (i.e., which user, which query).

## 3. Architecture Diagram

*For a visual representation of the reactive monitoring flow, please see the diagram in [`README.md`](README.md:1).*

## 4. Solution Components

The solution is composed of two main strategies: Proactive Controls and Reactive Monitoring.

### 4.1. Proactive Cost Controls

These mechanisms are designed to set hard and soft limits on BigQuery usage.

#### 4.1.1. Custom Cost Quotas
*   **Description:** Hard limits on the amount of data that can be processed by queries. When a quota is exceeded, BigQuery returns an error for new on-demand queries, preventing further spend.
*   **Implementation:**
    *   **Project-Level Quotas:** A daily aggregate limit for all users within a project. This serves as a primary safety net against catastrophic overruns.
    *   **User-Level Quotas:** A daily limit applied to individual users or service accounts. This is critical for preventing a single user or runaway script from consuming the entire project budget.
*   **Recommendation:** Implement both project and user-level quotas.

#### 4.1.2. Query and Schema Best Practices
*   **Description:** A set of enforced or strongly encouraged practices to ensure queries are written efficiently.
*   **Implementation:**
    *   **Table Partitioning:** All large, time-series tables **must** be partitioned by a date or timestamp column. Queries should be written to leverage these partitions to limit data scanning.
    *   **Table Clustering:** Tables frequently filtered or joined on specific high-cardinality columns (e.g., `customer_id`) should be clustered by those columns.
    *   **Query Dry Runs:** Integrate the use of query "dry runs" into development workflows. This allows developers to see the cost of a query *before* executing it.
    *   **Avoid `SELECT *`:** Enforce a policy against using `SELECT *` on large tables in favor of specifying only the required columns.

### 4.2. Reactive Monitoring & Alerting

This is the near real-time component of the architecture.

#### 4.2.1. Data Ingestion via Cloud Logging
*   **Description:** BigQuery automatically generates a detailed audit log in Cloud Logging upon the completion of every query job. This log is the source of our real-time data.
*   **Key Data Point:** The log's `protoPayload.serviceData.jobCompletedEvent.job.jobStatistics.totalBilledBytes` field provides the exact amount of data processed by the query. This log is generated within seconds of job completion.

#### 4.2.2. Real-Time Aggregation via Log-based Metrics
*   **Description:** A custom metric is created in Cloud Monitoring to extract and aggregate the `totalBilledBytes` value from the incoming audit logs.
*   **Implementation:**
    *   **Metric Type:** Distribution.
    *   **Filter:** A log filter to isolate only the relevant BigQuery job completion events.
    *   **Labels:** Extract key identifiers from the log entry as labels for the metric, such as `principalEmail` (the user/service who ran the query) and `project_id`. This is crucial for the "Top Offenders" analysis.

#### 4.2.3. Automated Alerting
*   **Description:** An alerting policy in Cloud Monitoring that continuously watches the custom metric and triggers notifications when a condition is met.
*   **Implementation:**
    *   **Condition:** It is highly recommended to use **Anomaly Detection**. This allows Monitoring to learn the normal rhythm of your BigQuery usage and alert only on statistically significant deviations, reducing alert fatigue. A simpler threshold-based alert can also be used (e.g., "alert if cost exceeds 10TB in 5 minutes").
    *   **Notification Channels:** Configure alerts to be sent to appropriate channels, such as PagerDuty for critical alerts and Slack/Email for warnings.

#### 4.2.4. Diagnostic Dashboard
*   **Description:** A centralized dashboard in Cloud Monitoring to visualize the cost data and diagnose alerts.
*   **Implementation (Key Widgets):**
    1.  **Scorecard:** Total billed TB in the last hour.
    2.  **Time Series Chart:** Billed bytes over time, with anomaly bands shown.
    3.  **Bar Chart (Top Offenders):** Billed bytes grouped by `principalEmail`.
    4.  **Log Panel:** A live view of the most recent, most expensive queries, showing the full query text and the user who ran it.

## 5. Incident Response Workflow

When an alert is received:
1.  The on-call person opens the **Diagnostic Dashboard**.
2.  They confirm the cost spike on the **Time Series Chart**.
3.  They identify the source of the spike using the **Top Offenders** chart.
4.  They view the exact query text in the **Log Panel**.
5.  They take corrective action, which may include canceling the running BigQuery job via its `job_id` or contacting the user directly.