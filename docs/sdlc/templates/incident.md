# Incident lesson: {{TITLE}}

Incident: {{CHANGE_ID}}
Service owner: {{SERVICE_OWNER}}
Status: investigating
Authoritative incident / channel: {{INCIDENT_AND_THREAD_LINKS}}
Related deploy, intent, PR, and commits: {{RELATED_RECORDS}}

## Detection and impact
{{METRIC_ANOMALY_TIME_AFFECTED_USERS_SYSTEMS_AND_EVIDENCE}}
Detector / baseline / tier / configuration version: {{DETECTOR_PROVENANCE}}

## Timeline and authority
| Time | Actor | Observation / action | Authorization / evidence |
| --- | --- | --- | --- |
| {{TIME}} | {{HUMAN_OR_AGENT_IDENTITY}} | {{OBSERVATION}} | {{REFERENCE}} |

## Diagnosis
Confirmed cause: {{CONFIRMED_CAUSE_OR_UNKNOWN}}
Hypotheses and uncertainties: {{HYPOTHESES}}

## Response and recovery
{{ALLOWED_ROUTE_USED_FIX_OR_ROLLBACK_AND_AUTHORIZATION}}
Recovery confirmation: {{ACTUAL_POST_ACTION_METRIC_AND_TIMESTAMP_OR_NOT_CONFIRMED}}

## Follow-up loop
Intent / next work: {{FOLLOWUP_INTENT}}
Permanent agent eval: {{EVAL_CASE_AND_PR_OR_PENDING_OWNER}}
Product regression test: {{TEST_OR_NOT_APPLICABLE}}
Relevant guidance / policy correction: {{CORRECTION_OR_NONE}}
Triage: {{FIX_SCHEDULE_DISMISS_AND_REAL_OWNER_DECISION}}

## What future investigations should know
{{DURABLE_LESSON_AND_RUNBOOK_UPDATE_WITH_EVIDENCE}}
