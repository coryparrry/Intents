A client sends a monotonically increasing sequence number with every update. A lower sequence number is rejected.

When the same sequence number and payload are received twice, the server returns the original acknowledgement without applying the update again.

The maximum update payload is 64 KiB.

A payload larger than 64 KiB receives status 413.

The server responds with status 409 when the same sequence number is reused with different content.

An acknowledgement contains the committed sequence number.

Clients retry transient failures with exponential backoff, starting at one second and capped at one minute.

Authentication failures are not retried automatically.

The sync cursor expires after seven days without use.

An expired cursor requires a full snapshot before incremental updates resume.

Each response includes a request identifier for diagnostic correlation.

An update is considered durable only after the acknowledgement has been received.