/** An error that is safe to show the client: a status, a stable code, a message. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly extra: Record<string, unknown> = {},
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(error: ApiError): Response {
  return json({ error: { code: error.code, message: error.message, ...error.extra } }, error.status, error.headers);
}

/**
 * Reads a JSON object body with a hard size cap, checked both from the
 * declared length and from what actually arrived, so a missing or lying
 * Content-Length cannot get past it.
 */
export async function readJsonObject(request: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new ApiError(413, "payload_too_large", "The request is too large.");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).length > maxBytes) {
    throw new ApiError(413, "payload_too_large", "The request is too large.");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ApiError(400, "bad_request", "The request body is not valid JSON.");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new ApiError(400, "bad_request", "The request body must be a JSON object.");
  }
  return parsed as Record<string, unknown>;
}

export function stringField(
  body: Record<string, unknown>,
  name: string,
  { min = 1, max }: { min?: number; max: number },
): string {
  const value = body[name];
  if (typeof value !== "string" || value.length < min || value.length > max) {
    throw new ApiError(400, "bad_request", `"${name}" must be a string of ${min} to ${max} characters.`);
  }
  return value;
}

/** Structured, single-line logs. Never pass transcripts, tokens or keys in here. */
export function log(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}
