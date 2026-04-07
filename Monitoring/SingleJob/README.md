# SingleJob — SQL Agent Last Run Status Alert

Monitors the last run outcome of every enabled SQL Agent job on a single server
and sends an HTML email alert when any job has failed or was canceled.
No email is sent when all jobs are healthy.

---

## How it works

### Section 1 — Regular jobs
- Queries `msdb.dbo.sysjobhistory` (step_id = 0 — overall job outcome) per job.
- Takes the **latest** record per job using `ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY instance_id DESC)`.
- Excludes all replication agent jobs (category `REPL-%`).
- Alerts if last run status is **Failed (0)** or **Canceled (3)**.
- If recovered (last run succeeded) — no alert.

### Section 2 — Replication agents (category `REPL-%`)
- Checks `msdb.dbo.sysjobactivity` for the current SQL Agent session.
- If the agent is **currently running** → excluded (continuous agents like Log Reader and Distribution are expected to run indefinitely).
- If **not running** and last completed run was Failed/Canceled → alert with dedicated message.

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
