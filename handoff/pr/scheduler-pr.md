# Scheduler PR body (open-uem/openuem-console, head: devilAPI:scheduled-tasks)

Related to open-uem/openuem-console#514 (feature request: scheduled tasks).
Depends on #499 (the code sits on top of that branch's features; the tab reuses its bulk update queueing) and on open-uem/ent#56 (the `scheduled_event` schema, pinned through `devilAPI/ent` until it lands).

## Summary

A **Scheduled tasks** tab in the Deploy section. Admins define tasks the console runs automatically against every enabled and admitted computer of the current organization (or one site):

| Task | What runs |
|---|---|
| Update all software | the same queueing as Deploy > Update all software: requests go to AGENTS_STREAM, so offline computers start when they connect again |
| Power off | `agent.poweroff.<id>` with no date, i.e. right now — only computers that are online can answer |
| Restart | `agent.restart.<id>`, same as above |
| Wake on LAN | a magic packet to every computer's MAC address through broadcast |

## Schedules

- **Recurring:** daily, weekly or monthly at a time of day, or any standard cron expression (validated with `robfig/cron`, which gocron already brings in).
- **Once:** a date and time in the future, interpreted in the console's local time. The form rejects dates in the past, and so does the server.

Simple schedules are stored as the cron expression the form builds (`15 8 * * *`, `30 22 * * 5`, `0 3 1 * *`), so a task edited later comes back with its frequency preselected. A custom cron expression is stored as typed.

## The list and its actions

One row per task: description (and site, if the task belongs to a single site), type, schedule, next run, last run, result (failed runs in red), enable/disable switch, and actions: run now, edit, delete (with a confirm).

- **Run now** executes the task in the background and answers immediately; the outcome is recorded when it finishes.
- **Enable/disable** registers and unregisters the job.
- A **one-time** task is disabled and unregistered after its single run; a one-time task whose time passed while the console was down is disabled instead of run ("their chance to run is gone").
- Jobs are registered with `gocron` singleton mode, so a slow run can't pile up on the next one.

## Persistence & startup

Tasks live in a new ent entity (`scheduled_event`) with the cron expression or the single date, the last run, whether it failed and the result summary. On startup the console registers the jobs of every enabled event from the database, so tasks survive restarts. The result summaries are stored in English because jobs run without a request locale.

The schema addition is contributed to `open-uem/ent` as a pull request; until that lands, this branch pins `github.com/devilAPI/ent` through a temporary `replace` in `go.mod` so reviewers can build it. The replace is one line (plus the matching `go.sum` entries) to drop once upstream ent contains the schema.

Requests are scoped like the rest of the Deploy section: a task only ever touches enabled, admitted agents of its organization, and editing or running a task from a site only works if the task belongs to that site or to the whole organization. The routes exist for the three mounts (global, tenant and tenant/site).

## Translations

en, de, es, ca, fr, pt and no.

## Testing

Tested with a Docker deployment against a Windows endpoint (the runner of your agents): create tasks of every type and frequency, edit them, disable them, run them now, delete them, restart the console and watch its jobs being registered again, and see a daily task fire.
