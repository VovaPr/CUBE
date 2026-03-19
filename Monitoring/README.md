# SQL Server Job Monitoring Solution

A comprehensive T-SQL solution to monitor SQL Server Agent jobs from a central server. It collects job statuses into `dba_db` under the `Monitoring` schema and sends periodic email alerts when jobs fail.

## Requirements

- SQL Server 2016 or later
- SQL Server Agent enabled
- Database Mail configured for email notifications

## Architecture

**Central Monitoring Server - `DBMGMT.cubecloud.local\SQL01,10010` (origin\Master)**
- runs the SQL Agent job **DBA - Common Monitoring Alerts** every 5 minutes
- receives alert data pushed from target servers into central `dba_db`
- executes `Monitoring.SP_SendAlerts` on central data and sends emails

On each **Target Server**:
- `Monitoring.Jobs` table stores the latest job status for that server
- the same `Monitoring.SP_MonitoringJobs` procedure is deployed locally to
  collect statuses and populate alerts
- a local SQL Agent job (created by the setup script) executes the procedure
  on the target schedule (hourly by default)

The **Central Server** also has all of the above objects; in addition it runs a
special job (`DBA - Common Monitoring Alerts`) every five minutes that reads
already-centralized alerts and dispatches emails.

## Project Structure

- **setup/central/** - Central server setup (DBMGMT.cubecloud.local\SQL01,10010):
  - `01_create_schema.sql` – creates `Monitoring` schema and tables
  - `02_create_stored_procedure.sql` – defines `Monitoring.SP_MonitoringJobs`
  - `03_create_send_alerts_procedure.sql` – defines `Monitoring.SP_SendAlerts`
  - `04_create_agent_job.sql` – creates two jobs:
    - **DBA - Collect Job Status** — runs at **:01** every hour
    - **DBA - Common Monitoring Alerts** — runs at **:05** every hour and sends email from central table

- **setup/central/rollback/** – Central rollback scripts:
  - `01_rollback_agent_job.sql` – removes central jobs and operator
  - `02_rollback_send_alerts_procedure.sql` – drops `Monitoring.SP_SendAlerts`
  - `03_rollback_stored_procedure.sql` – drops `Monitoring.SP_MonitoringJobs`
  - `04_rollback_schema.sql` – drops monitoring tables and schema

- **setup/target/** – Target server setup (all monitored servers):
  - `01_create_schema.sql` – creates `Monitoring` schema and tables
  - `02_create_stored_procedure.sql` – defines `Monitoring.SP_MonitoringJobs` (collect + fill alerts + auto-resolve)
  - `03_create_agent_job.sql` – creates **DBA - Monitoring Alerts** job (every hour at **:01**)
  - target setup also creates `Monitoring.Servers` with `DBMGMT.cubecloud.local\SQL01,10010`

- **Monitoring/** – miscellaneous utilities

## Installation

### Central Server (DBMGMT.cubecloud.local\SQL01,10010)

Run the setup scripts **in order** on `DBMGMT.cubecloud.local\SQL01,10010`:

```sql
-- 1. Create schema and tables
USE master; GO
:r "setup\central\01_create_schema.sql"

-- 2. Create monitoring procedure
USE master; GO
:r "setup\central\02_create_stored_procedure.sql"

-- 3. Create alert-sending procedure
USE master; GO
:r "setup\central\03_create_send_alerts_procedure.sql"

-- 4. Create Agent job (runs every 5 minutes)
USE master; GO
:r "setup\central\04_create_agent_job.sql"
```

Then configure Database Mail and email recipient:

```sql
-- Enable Database Mail if needed
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;

-- Update email settings in the alert procedure
-- (Edit setup\central\03_create_send_alerts_procedure.sql before running it)
-- or modify after creation:
ALTER PROCEDURE Monitoring.SP_SendAlerts
  @EmailRecipient NVARCHAR(256) = '559c4de8.cube.global@emea.teams.ms',
    @MailProfile NVARCHAR(256) = 'SQLAlerts'
```

Operator notifications are also configured by setup job scripts:

- Operator name: `Monitoring`
- Operator email: `559c4de8.cube.global@emea.teams.ms`
- SQL Agent jobs are created with `@notify_level_email = 2` (notify on job failure)
- This means you receive alerts from both the stored procedure and failed job events

### Target Servers (All Others)

Run the setup scripts **in order** on each target server:

```sql
-- 1. Create schema and tables
USE master; GO
:r "setup\target\01_create_schema.sql"

-- 2. Create monitoring procedure
USE master; GO
:r "setup\target\02_create_stored_procedure.sql"

-- 3. Create Agent job (runs every hour)
USE master; GO
:r "setup\target\03_create_agent_job.sql"
```

### Target Push Prerequisite: One Aggregated Server Table

Each target server stores its own registration/heartbeat row in
`dba_db.Monitoring.Servers` (created by `setup/target/01_create_schema.sql`).
`Monitoring.SP_MonitoringJobs` refreshes `ModifiedAt` on each run.

```sql
USE dba_db;
GO
SELECT ServerName, CentralServerName, IsActive, CreatedAt, ModifiedAt
FROM Monitoring.Servers;
GO
```

If you need to re-register a target row manually, use:

```sql
MERGE Monitoring.Servers AS dst
USING (SELECT CAST(@@SERVERNAME AS NVARCHAR(256)) AS ServerName) AS src
  ON dst.ServerName = src.ServerName
WHEN MATCHED THEN
  UPDATE SET
    CentralServerName = N'DBMGMT.cubecloud.local\SQL01,10010',
    IsActive = 1,
    ModifiedAt = GETDATE()
WHEN NOT MATCHED THEN
  INSERT (ServerName, CentralServerName, IsActive)
  VALUES (src.ServerName, N'DBMGMT.cubecloud.local\SQL01,10010', 1);
```

## Monitoring Tables

### Monitoring.Jobs
Holds the latest status for every monitored job:

- `JobID` – identity key
- `ServerName` – source server
- `JobName` – job name
- `SQLJobID` – sysjobs.job_id value
- `LastRunStatus` – 0 = failed, 1 = succeeded
- `LastRunDate`, `LastRunDuration`, `NextRunDate`
- `IsEnabled` – job enabled flag

### Monitoring.FailedJobsAlerts
Tracks active failure alerts:

- `AlertID`, `ServerName`, `JobName`
- `FailureCount` – occurrences within the last hour
- `FirstFailureTime`, `LastFailureTime`
- `AlertSentTime`, `IsResolved`, `ResolutionTime`

### Monitoring.JobHistory
(Optional) historical log of executions if desired

## Useful Queries

**Current active failures:**
```sql
SELECT *
FROM Monitoring.FailedJobsAlerts
WHERE IsResolved = 0
ORDER BY LastFailureTime DESC;
```

**Summary by server:**
```sql
SELECT ServerName,
       COUNT(*) AS TotalJobs,
       SUM(CASE WHEN LastRunStatus = 0 THEN 1 ELSE 0 END) AS FailedCount,
       SUM(CASE WHEN IsEnabled = 0 THEN 1 ELSE 0 END) AS DisabledCount
FROM Monitoring.Jobs
GROUP BY ServerName;
```

**Check target job history:**
```sql
SELECT TOP 10 sj.name,
             sjh.run_date,
             sjh.run_status,
             sjh.run_duration
FROM msdb.dbo.sysjobhistory sjh
JOIN msdb.dbo.sysjobs sj
  ON sjh.job_id = sj.job_id
WHERE sj.name = 'DBA - Monitoring Alerts'
ORDER BY sjh.run_date DESC;
```

**Check central collect job history:**
```sql
SELECT TOP 10 sj.name,
             sjh.run_date,
             sjh.run_status,
             sjh.run_duration
FROM msdb.dbo.sysjobhistory sjh
JOIN msdb.dbo.sysjobs sj
  ON sjh.job_id = sj.job_id
WHERE sj.name = 'DBA - Collect Job Status'
ORDER BY sjh.run_date DESC;
```

**Check central alert job history:**
```sql
SELECT TOP 10 sj.name,
             sjh.run_date,
             sjh.run_status,
             sjh.run_duration
FROM msdb.dbo.sysjobhistory sjh
JOIN msdb.dbo.sysjobs sj
  ON sjh.job_id = sj.job_id
WHERE sj.name = 'DBA - Common Monitoring Alerts'
ORDER BY sjh.run_date DESC;
```

**Check central alert job steps (must be 1 step):**
```sql
SELECT s.step_id, s.step_name, s.on_success_action, s.on_success_step_id
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j
  ON j.job_id = s.job_id
WHERE j.name = 'DBA - Common Monitoring Alerts'
ORDER BY s.step_id;
```

**Check aggregated server rows on central:**
```sql
SELECT ServerName, CentralServerName, IsActive, ModifiedAt
FROM dba_db.Monitoring.Servers
ORDER BY ServerName;
```

**Check unresolved alerts currently copied to central:**
```sql
SELECT ServerName, JobName, FailureCount, FirstFailureTime, LastFailureTime, AlertSentTime
FROM dba_db.Monitoring.FailedJobsAlerts
WHERE IsResolved = 0
ORDER BY LastFailureTime DESC;
```

## Troubleshooting

- **Emails not sending:**
  - `EXEC msdb.dbo.sysmail_help_status_sp` to check mail status
  - verify mail profile and credentials
  - ensure `Database Mail XPs` is enabled

- **Statuses not updating:**
  - confirm the Agent jobs **DBA - Monitoring Alerts** (targets, at :01) and **DBA - Collect Job Status** / **DBA - Common Monitoring Alerts** (central, at :01/:05) are scheduled and running
  - check security/access to target servers
  - examine job history for errors

## Support

Contact the DBA team for assistance with setup or issues.

- Verify mail profile and credentials
- Ensure Database Mail XPs is enabled

### Statuses not updating
- Check that the SQL Server Agent jobs are running
- Verify access permissions on target servers
- Review the Agent job history logs

(*The above support steps also apply to non‑central servers.*)
