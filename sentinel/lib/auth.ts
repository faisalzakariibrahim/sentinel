import jwt from "jsonwebtoken";
import { env } from "./env";

export class AuthError extends Error {}

export interface AuthenticatedUser {
  userId: string;
}

// Verifies the caller's own Supabase access token (HS256, signed with the
// project's JWT secret) — never a shared static bearer. This is the
// authentication boundary for any endpoint a browser client calls directly;
// the resulting userId must be enforced against row ownership downstream.
export function verifySupabaseAccessToken(
  authorizationHeader: string | string[] | undefined,
): AuthenticatedUser {
  const header = Array.isArray(authorizationHeader) ? authorizationHeader[0] : authorizationHeader;
  const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : undefined;
  if (!token) throw new AuthError("missing bearer token");

  let payload: jwt.JwtPayload;
  try {
    // Pin the algorithm explicitly — never trust the token's own `alg` header.
    payload = jwt.verify(token, env("SUPABASE_JWT_SECRET"), {
      algorithms: ["HS256"],
    }) as jwt.JwtPayload;
  } catch {
    throw new AuthError("invalid or expired token");
  }

  // Supabase issues `aud: "authenticated"` for logged-in end users; this
  // excludes the service role key and any non-user-session token.
  if (payload.aud !== "authenticated" || typeof payload.sub !== "string" || !payload.sub) {
    throw new AuthError("token is not an authenticated user session");
  }

  return { userId: payload.sub };
}
