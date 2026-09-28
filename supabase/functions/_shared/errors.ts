// Structured, non-leaking error responses for the Edge Functions.
//
// WHY THIS EXISTS
// ---------------
// Every function in this directory ends with a catch-all. Before this file
// those catch-alls were:
//
//   return json({ error: "An internal error occurred" }, 500);
//
// which is correct about leaking and wrong about everything else: it throws
// the real cause away. The message reaches the server console and nowhere
// else, so "the recharge failed for one user on Tuesday" is undiagnosable
// without pulling Edge Function logs out of the Supabase Dashboard by hand
// and reading them by eye. `staff_errors.ts` was written for exactly this
// reason on the staff gateways; this generalises it.
//
// The contract:
//
//   * The client gets a STABLE machine code plus a plain sentence. It never
//     gets a stack, a SQL string, a table name, an upstream URL, or the text
//     of a driver error. A Postgres message can contain a row's contents
//     ("duplicate key value violates unique constraint wallets_user_id_key"),
//     which is a data leak with a 500 on it.
//   * The server gets everything: the real error, the stack, and a request
//     id that also goes to the client.
//
// The request id is the important part. `request_id` in the response body is
// the join key between "the user said it failed" and "here is the log line".
// Without it the only way to correlate is by timestamp, which does not work
// on a busy day.
//
// Note the deliberate asymmetry: `error` (the human sentence) is safe to
// show a user, `detail` is not and is not sent. Internals go to console.

import { corsHeaders } from "./client.ts";

/**
 * A stable code the client can branch on. Keep these in sync with
 * `lib/core/resilience/failure_mapper.dart` — the Dart side classifies a
 * function error from the HTTP status and the code, and a code it does not
 * recognise degrades to a generic message, which is safe but unhelpful.
 */
export type ErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "invalid_request"
  | "rate_limited"
  | "conflict"
  | "insufficient_balance"
  | "upstream_unavailable"
  | "internal";

/** The plain sentence shown to a user, keyed by code. */
const MESSAGES: Record<ErrorCode, string> = {
  unauthorized: "Please sign in again to continue.",
  forbidden: "You do not have permission to do that.",
  not_found: "We could not find that.",
  invalid_request: "Please check the details and try again.",
  rate_limited: "Too many requests. Please wait a moment and try again.",
  conflict: "That already exists. Please choose something different.",
  insufficient_balance: "Your wallet balance is too low for this.",
  upstream_unavailable: "We could not reach our servers. Please try again.",
  internal: "Something went wrong. Please try again.",
};

/**
 * Status defaults per code. Overridable, because the same code can honestly
 * mean different things in different places — a `conflict` is 409 almost
 * everywhere and 400 where it means "your idempotency key was reused".
 */
const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  invalid_request: 400,
  rate_limited: 429,
  conflict: 409,
  insufficient_balance: 402,
  upstream_unavailable: 503,
  internal: 500,
};

/** A short id we can print in a log and show a user. Not a secret. */
function requestId(): string {
  return crypto.randomUUID().slice(0, 8);
}

/**
 * Log the real cause server-side and return a safe, structured response.
 *
 * `console.error` is the sink. It is what the Supabase dashboard surfaces,
 * and it is the only place the underlying error exists once this returns.
 */
export function fail(
  code: ErrorCode,
  opts: {
    /** The actual thrown thing. Logged, never returned. */
    cause?: unknown;
    /** Which function and operation, for the log line. */
    where: string;
    /** Overrides the default status for this code. */
    status?: number;
    /** Extra server-side context. Logged, never returned. */
    detail?: Record<string, unknown>;
  },
): Response {
  const rid = requestId();
  const message = MESSAGES[code] ?? MESSAGES.internal;
  const status = opts.status ?? STATUS[code] ?? 500;

  // Server side: everything.
  const err = opts.cause instanceof Error ? opts.cause : undefined;
  console.error(
    JSON.stringify({
      level: "error",
      request_id: rid,
      where: opts.where,
      code,
      status,
      // error/stack are the diagnostic value; they stay here.
      error: err?.message ?? (opts.cause ? String(opts.cause) : undefined),
      stack: err?.stack,
      detail: opts.detail,
    }),
  );

  // Client side: a sentence and a join key. No internals.
  return new Response(
    JSON.stringify({
      error: message,
      code,
      request_id: rid,
    }),
    {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
}

/** Convenience for the overwhelmingly common `internal` case. */
export function failInternal(
  where: string,
  cause: unknown,
  detail?: Record<string, unknown>,
): Response {
  return fail("internal", { cause, where, detail });
}

/**
 * The catch-all every function's top-level handler should end with.
 *
 * Preserves the existing `throw new Response(...)` auth pattern used by
 * `requireUser`, which is why a Response is passed through untouched rather
 * than being reformatted — an auth rejection already has the right shape.
 */
export function handleCatch(
  e: unknown,
  where: string,
  detail?: Record<string, unknown>,
): Response {
  if (e instanceof Response) return e;
  return failInternal(where, e, detail);
}
