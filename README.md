# Sentinel

Personal AI OS / agentic control plane: risk-scored approval tiers, a Judge
verification step, structured intent decomposition, memory, and Mission
Control dashboard views on Supabase.

Everything lives under [`sentinel/`](sentinel/) — start with
[`sentinel/README.md`](sentinel/README.md).

| Path | What |
|---|---|
| `sentinel/supabase/migrations/` | Schema migrations — apply in filename order |
| `sentinel/supabase/tests/security/` | Local Postgres security/integrity test suite |
| `sentinel/agents/prompts/` | Decomposer and Judge system prompts |
| `sentinel/scripts/set_sentinel_secret.sh` | Sets the `sentinel_executor` password |
