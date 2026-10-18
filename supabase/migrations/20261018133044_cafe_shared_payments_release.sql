-- Release-history marker for the atomic production batch applied by Supabase MCP.
-- Version 20261018133044 is the actual recorded production batch version.
-- The nine canonical source migrations were executed together and registered
-- individually in that same transaction, before frontend deployment.
-- Their DDL remains in their original source files; on a fresh database those
-- run first. This marker therefore has no additional schema or data operation.
select 1;
