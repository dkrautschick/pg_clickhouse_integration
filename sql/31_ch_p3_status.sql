-- Path 3: what the refresh timer is doing.
SELECT view, status, last_success_time, next_refresh_time, read_rows, written_rows, exception
FROM system.view_refreshes
WHERE database = '${CH_DB}'
FORMAT Vertical;
