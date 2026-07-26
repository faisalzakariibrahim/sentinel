import { PoolClient, Pool } from "pg";

export type AuditEvent =
  | "decomposed"
  | "executed"
  | "judged"
  | "escalated"
  | "approved"
  | "rejected"
  | "repaired"
  | "failed"
  | "blocked"
  | "completed";

export async function logAudit(
  client: Pool | PoolClient,
  entry: { taskId?: string; eventType: AuditEvent; actor: string; payload?: unknown },
): Promise<void> {
  await client.query(
    `insert into audit_log (task_id, event_type, actor, payload) values ($1, $2, $3, $4)`,
    [entry.taskId ?? null, entry.eventType, entry.actor, entry.payload ? JSON.stringify(entry.payload) : null],
  );
}
