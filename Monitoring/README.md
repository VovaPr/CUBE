# SQL Server Job Monitoring Solution

A comprehensive T-SQL solution to monitor SQL Server Agent jobs from a central server. It collects job statuses into `dba_db` under the `Monitoring` schema and sends periodic email alerts when jobs fail.

## Requirements

- SQL Server 2016 or later
- SQL Server Agent enabled
- Database Mail configured for email notifications

## Architecture

**Central Monitoring Server - `DBMGMT.cubecloud.local\SQL01,10010` (origin\Master)**
- runs the SQL Agent job **DBA - Monitoring Jobs** (:01 hourly) with 4 steps:
  1) collect current central jobs into `Monitoring.Jobs`
  2) refresh central `Monitoring.FailedJobsAlerts`
  3) loop all active targets and pull/persist target alerts into central table via `sqlcmd`
  4) send operator notification email
- orchestrates target pull via `sqlcmd` only (no linked servers)
- imports target `Monitoring.FailedJobsAlerts` as JSON snapshot and merges by incident key (`ServerName + JobName + FirstFailureTime`) to preserve history
- executes `Monitoring.SP_SendAlerts` on central aggregated data and sends emails

On each **Target Server**:
- `Monitoring.Jobs` table stores the latest job status for that server
- two procedures are deployed locally:
  1) `Monitoring.SP_CollectJobs`
  2) `Monitoring.SP_RefreshFailedJobsAlerts`
- a local SQL Agent job `DBA - Monitoring Jobs` (every 30 minutes, 2 steps):
  1) calls `Monitoring.SP_CollectJobs`
  2) calls `Monitoring.SP_RefreshFailedJobsAlerts`

The **Central Server** also has all of the above objects and runs the orchestration job.

## Project Structure

- **setup/central/** - Central server setup (DBMGMT.cubecloud.local\SQL01,10010):
  - `01_create_schema.sql` – creates `Monitoring` schema/tables including `Monitoring.TargetPullLog`, final `Monitoring.Servers` layout, and central row
  - `02_create_stored_procedure.sql` – defines `Monitoring.SP_CollectJobs`, `Monitoring.SP_RefreshFailedJobsAlerts`, `Monitoring.SP_PullTargetFailedJobsAlerts`
  - `03_create_send_alerts_procedure.sql` – defines `Monitoring.SP_SendAlerts` (one email per failed alert row)
  - `04_create_agent_job.sql` – creates **DBA - Monitoring Jobs** (runs at **:01** every hour):
    - Step 1: Collect Current Jobs → calls `Monitoring.SP_CollectJobs`
    - Step 2: Refresh Failed Alerts → calls `Monitoring.SP_RefreshFailedJobsAlerts`
    - Step 3: Pull Target Failed Alerts → calls `Monitoring.SP_PullTargetFailedJobsAlerts`
    - Step 4: Send Email Alerts → calls `Monitoring.SP_SendAlerts`
  - `05_prepare_target_grants.sql` – grants required access and prints target-side utility SQL

- **setup/central/rollback/** – Central rollback scripts:
  - `01_rollback_agent_job.sql` – removes central jobs and operator
  - `02_rollback_send_alerts_procedure.sql` – drops `Monitoring.SP_SendAlerts`
  - `03_rollback_stored_procedure.sql` – drops `Monitoring.SP_CollectJobs`, `Monitoring.SP_RefreshFailedJobsAlerts`, `Monitoring.SP_PullTargetFailedJobsAlerts` (and legacy `Monitoring.SP_MonitoringJobs` if found)
  - `04_rollback_schema.sql` – drops monitoring tables and schema

- **setup/target/** – Target server setup (all monitored servers):
  - `01_create_schema.sql` – creates `Monitoring` schema and tables, including the final `Monitoring.Servers` layout and initial central/target rows
  - `02_create_servers_table.sql` – recreates `Monitoring.Servers` with the final layout and re-seeds central/target rows
  - `03_create_stored_procedure.sql` – defines `Monitoring.SP_CollectJobs` and `Monitoring.SP_RefreshFailedJobsAlerts`
  - `04_create_agent_job.sql` – creates **DBA - Monitoring Jobs** job (every 30 minutes):
    - Step 1: Collect Jobs → calls `Monitoring.SP_CollectJobs`
    - Step 2: Refresh Failed Alerts → calls `Monitoring.SP_RefreshFailedJobsAlerts`
  - `05_link_central_and_target.sql` – utility script that rebuilds local `Monitoring.Servers` rows and can execute target-to-central registration immediately
  - target setup uses `DBMGMT\SQL01,10010` as `CentralServerName`

- **setup/target/rollback/** – Target rollback scripts:
  - `01_rollback_agent_job.sql` – removes target job and operator
  - `02_rollback_stored_procedure.sql` – drops `Monitoring.SP_CollectJobs`, `Monitoring.SP_RefreshFailedJobsAlerts` (and legacy `Monitoring.SP_MonitoringJobs` if found)
  - `03_rollback_servers_table.sql` – drops `Monitoring.Servers` only (use for partial rollback)
  - `04_rollback_schema.sql` – drops monitoring tables and schema

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

-- 4. Create Agent job (hourly schedule: :01)
USE master; GO
:r "setup\central\04_create_agent_job.sql"

-- 5. Prepare grants for target execution
USE master; GO
:r "setup\central\05_prepare_target_grants.sql"
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
- You receive: (1) per-failed-job emails from `SP_SendAlerts`; (2) optional SQL Agent job-failure notifications

### Email Alert Format

- Subject format: `Failed Job on <ServerName> Job: <JobName>`
- Delivery mode: one email per unresolved failed-alert row that passes resend window
- Body format: HTML (`Server` and `Job` are bold)
- Resend window: alert row is re-sent only if `AlertSentTime` is null or older than 50 minutes

### Target Servers (All Others)

Run the setup scripts **in order** on each target server:

```sql
-- 1. Create schema and tables
USE master; GO
:r "setup\target\01_create_schema.sql"

-- 2. Recreate Monitoring.Servers with final schema and seed central/target rows
USE master; GO
:r "setup\target\02_create_servers_table.sql"

-- 3. Create monitoring procedure
USE master; GO
:r "setup\target\03_create_stored_procedure.sql"

-- 4. Create Agent job (runs every 30 minutes)
USE master; GO
:r "setup\target\04_create_agent_job.sql"
```

### Central Pull Prerequisite: One Aggregated Server Table

Each target server stores its own registration/heartbeat row in
`dba_db.Monitoring.Servers` (created by `setup/target/01_create_schema.sql` and refreshable via `setup/target/02_create_servers_table.sql`).
`Monitoring.SP_CollectJobs` refreshes `ModifiedAt` on each run.

```sql
USE dba_db;
GO
SELECT ServerName, CentralServerName, IsActive, Central, Target, CreatedAt, ModifiedAt
FROM Monitoring.Servers;
GO
```

If you need to re-register a target row manually, use:

```sql
DECLARE @TargetInstanceName NVARCHAR(256) =
    CAST(SERVERPROPERTY('MachineName') AS NVARCHAR(256)) +
    ISNULL(N'\' + CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(256)), N'');

MERGE Monitoring.Servers AS dst
USING (SELECT @TargetInstanceName AS ServerName) AS src
  ON dst.ServerName = src.ServerName
WHEN MATCHED THEN
  UPDATE SET
    CentralServerName = N'DBMGMT\SQL01,10010',
    IsActive = 1,
    Central = 0,
    Target = 1,
    ModifiedAt = GETDATE()
WHEN NOT MATCHED THEN
  INSERT (ServerName, CentralServerName, IsActive, Central, Target)
  VALUES (src.ServerName, N'DBMGMT\SQL01,10010', 1, 0, 1);
```

There is no dedicated rollback step for `05_prepare_target_grants.sql` because it is a utility/security step rather than a `Monitoring` schema object deployment. Use normal security rollback procedures if those grants must be reverted.

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
WHERE sj.name = 'DBA - Monitoring Jobs'
ORDER BY sjh.run_date DESC;
```

**Check central monitoring job history:**
```sql
SELECT TOP 10 sj.name,
             sjh.run_date,
             sjh.run_status,
             sjh.run_duration
FROM msdb.dbo.sysjobhistory sjh
JOIN msdb.dbo.sysjobs sj
  ON sjh.job_id = sj.job_id
WHERE sj.name = 'DBA - Monitoring Jobs'
ORDER BY sjh.run_date DESC;
```

**Check central monitoring job steps (must be 4 steps):**
```sql
SELECT s.step_id, s.step_name, s.on_success_action, s.on_success_step_id
FROM msdb.dbo.sysjobsteps s
JOIN msdb.dbo.sysjobs j
  ON j.job_id = s.job_id
WHERE j.name = 'DBA - Monitoring Jobs'
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
  - confirm Agent job **DBA - Monitoring Jobs** is scheduled and running on central every hour at :01
  - on target servers, confirm **DBA - Monitoring Jobs** is scheduled and running every 30 minutes
  - check security/access to target servers
  - examine job history for errors

## Support

Contact the DBA team for assistance with setup or issues.

- Verify mail profile and credentials
- Ensure Database Mail XPs is enabled
