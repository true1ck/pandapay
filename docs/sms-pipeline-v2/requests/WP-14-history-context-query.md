# WP-14 history context query

The 20,000-message full-runtime benchmark exceeded the two-minute budget at checkpoint 065d2b7.

EXPLAIN QUERY PLAN showed that the contextSince join started from the recent-fact date index, then scanned all account events and their JSON legs per fact. The resulting nested scans multiplied the two growing history sets.

A correlated EXISTS query with CROSS JOIN keeps each event leg before its fact lookup. SQLite then uses the fact primary key (namespace,fact_id), and EXISTS returns each event once. The loop-order control is documented in the [SQLite optimizer overview](https://www.sqlite.org/optoverview.html#manual_control_of_query_plans_using_cross_join).

The receipt-time boundary uses the same fixed-width fractional UTC representation as FactStore, including exact microsecond boundaries. A regression covers old printed dates, multiple event legs and account isolation.

After the query change, the unchanged full-runtime desktop benchmark processed 20,000 messages in **103,158 ms** and passed its two-minute assertion. The nine EventStore tests also passed. The physical mid-range Android performance gate remains a device check.
