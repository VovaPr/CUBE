# SingleJob — SQL Agent Last Run Status Alert

Monitors the last run outcome of every enabled SQL Agent job on a single server
and sends an HTML email alert when any job has failed or was canceled.
No email is sent when all jobs are healthy.

---

## How it works

### Stored Procedure Flow

The procedure `dbo.SP_SendSqlJobsLastRunStatusAlert` runs in `DBA_DB` and writes candidate alerts into a temp table (`#Result`).
If `#Result` is empty, it exits without email.

### Step 1 - Build latest job outcome snapshot
- Source: `msdb.dbo.sysjobhistory`, `step_id = 0` only (job-level outcome row, not per-step rows).
- For each `job_id`, the latest execution is selected by:
    `ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC)`.

### Step 2 - Evaluate regular SQL Agent jobs
- Includes only enabled jobs: `sj.enabled = 1`.
- Excludes replication categories: `category NOT LIKE 'REPL-%'`.
- Adds alert rows when latest status is:
    - `0` = Failed
    - `3` = Canceled

### Step 3 - Evaluate replication jobs separately
- Includes only enabled jobs in replication categories: `category LIKE 'REPL-%'`.
- Checks current execution state in `msdb.dbo.sysjobactivity` for the latest SQL Agent session.
- Decision:
    - If replication job is currently running -> healthy (no alert row).
    - If not running and latest completed run is Failed/Canceled -> alert row is added.

This separation is intentional because replication agents can run continuously by design.

### Step 4 - Send email only when alert exists
- If no rows were added to `#Result`, procedure returns immediately.
- If rows exist, HTML body is generated and sent via `msdb.dbo.sp_send_dbmail`.
- Subject default: `<SERVERNAME> SQL Jobs Last Run Status Alert` (from `@@SERVERNAME`), unless overridden by `@Subject`.

---

## Objects

| Object | Database | Description |
|---|---|---|
| `dbo.SP_SendSqlJobsLastRunStatusAlert` | `DBA_DB` | Stored procedure — core logic and email dispatch |
| `DBA - SQL Jobs Last Run Status Alert` | `msdb` | SQL Agent job — runs the procedure on a schedule |
| `DBA - SQL Jobs Last Run Status Alert - Hourly at :01` | `msdb` | Schedule — every hour at :01 |

---

## Setup

Run scripts in order on the target server:

| # | Script | Description |
|---|---|---|
| 1 | `setup/01_create_stored_procedure.sql` | Creates `SP_SendSqlJobsLastRunStatusAlert` in `DBA_DB` |
| 2 | `setup/02_create_agent_job.sql` | Creates the SQL Agent job and schedule in `msdb` |

### Prerequisites
- `DBA_DB` database must exist.
- Database Mail profile `SQLAlerts` must be configured.
- SQL Agent must be running.

---

## Rollback

Run scripts in order to fully remove all objects:

| # | Script | Reverses |
|---|---|---|
| 1 | `setup/rollback/01_rollback_agent_job.sql` | Drops the SQL Agent job and schedule |
| 2 | `setup/rollback/02_rollback_stored_procedure.sql` | Drops the stored procedure from `DBA_DB` |

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `@MailProfile` | `SQLAlerts` | Database Mail profile name |
| `@Recipients` | Teams channel address | Semicolon-separated recipient list |
| `@Subject` | `<SERVERNAME> SQL Jobs Last Run Status Alert` | Email subject — auto-populated from `@@SERVERNAME` if not provided |

---

## Identify replication jobs on the server

```sql
SELECT
     sj.[name]   AS JobName
    ,sj.enabled
    ,sc.[name]   AS Category
FROM msdb.dbo.sysjobs sj
JOIN msdb.dbo.syscategories sc
    ON sj.category_id = sc.category_id
   AND sc.category_class = 1
WHERE sc.[name] LIKE N'REPL-%'
ORDER BY sc.[name], sj.[name];
```

## Run the alert job manually

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'DBA - SQL Jobs Last Run Status Alert';
```
