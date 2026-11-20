# Scheduler issue body (open-uem/openuem-console, feature request)

**Is your feature request related to a problem? Please describe.**

OpenUEM's bulk actions are one-shot: someone has to sit in front of the console to run them. The software updates, power off, restart and Wake on LAN actions would often be useful at fixed times — updates over night when nobody works and nothing blocks an installer, power off in the evening to save energy, Wake on LAN in the morning before users arrive — but today an admin has to trigger each one by hand, or build a separate automation against the console.

**Describe the solution you'd like**

A **Scheduled tasks** tab in the Deploy section where admins define tasks the console runs automatically against every enabled and admitted computer of an organization (or of one site):

- update all software (offline computers start when they connect again, like the manual Update all software action),
- power off,
- restart,
- Wake on LAN.

Two kinds of schedule, both validated by the console:

- **Recurring**: daily, weekly or monthly at a time of day, or any standard cron expression,
- **Once**: a date and time in the future, interpreted in the console's local time.

The list shows every task with its schedule, when it runs next, when it last ran and with what result, and a task can be enabled and disabled, edited, run right away, or deleted. Many tasks can coexist and the schedule survives a console restart, because the jobs are registered from the database at startup.

**Describe alternatives you've considered**

- **OS-level scheduled tasks on each computer.** They must be deployed and maintained per computer, they don't appear in the console, and Wake on LAN / update-all runs aren't local actions anyway.
- **Cron on the console host calling the agent CLI or messaging.** No overview for other admins, no per-organization scoping, no result stored next to the task.

**Additional context**

The console's existing gocron task scheduler can drive the jobs; the tasks' parameters only need a small ent schema addition (`scheduled_event`), which will be contributed as an open-uem/ent pull request. A working implementation for the console exists and will be linked here.
