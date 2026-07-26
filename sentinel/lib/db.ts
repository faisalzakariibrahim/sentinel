import { Pool, PoolClient } from "pg";
import { env } from "./env";

let pool: Pool | undefined;

export function db(): Pool {
  if (!pool) {
    pool = new Pool({
      connectionString: env("SENTINEL_DB_URL"),
      max: 3,
      idleTimeoutMillis: 10_000,
    });
  }
  return pool;
}

export async function withTx<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await db().connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    await client.query("rollback").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}
