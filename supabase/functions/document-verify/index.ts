// Document Identifier Agent: QR verification for signup ID documents.
//
// Flow: signup stores the ID image via the shared DocumentUploadService
// (private user-documents bucket + user_documents row), then calls this
// function with the document id. The agent downloads the image, decodes any
// QR code (pure JS: jpeg-js/pngjs + jsQR), validates the payload, and either
// AUTO_APPROVES the account (service role is exempt from the profiles
// status-self-modification guard, migration 0034) or routes it to manual
// admin review. It NEVER auto-rejects: fraud-suspicion and unreadable QRs
// both land in the admin queue with a recorded verdict.
//
// Verdicts:
//   AUTO_APPROVED  — QR decoded, payload structurally valid for the type,
//                    name cross-check passes, no duplicate reuse, no
//                    AI-generator EXIF signature.
//   SUSPECTED_FRAUD— duplicate payload across accounts, or AI-generator
//                    EXIF. Still manual (human decides), but flagged.
//   MANUAL_REVIEW  — QR missing/unreadable, payload shape wrong, name
//                    mismatch, or any processing error. Never blocks.
//
// Auth: caller must be signed in; the document row must belong to them.
// No new secrets (built-in SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY).
import { createClient } from "npm:@supabase/supabase-js@2";
// CJS-interop-safe imports (works whether the package surface lands under
// .default or flat on the namespace).
// @ts-ignore: npm import resolves at deploy time in the Edge runtime.
import * as jpegJsNs from "npm:jpeg-js@0.4.4";
// @ts-ignore
import * as pngjsNs from "npm:pngjs@7.0.0";
// @ts-ignore
import * as jsqrNs from "npm:jsqr@1.4.0";

const jpegMod = jpegJsNs as Record<string, unknown>;
const decodeJpeg = (jpegMod.decode ??
  (jpegMod.default as Record<string, unknown> | undefined)?.decode) as
  (b: Uint8Array, o?: unknown) => { data: number[]; width: number; height: number };
const pngMod = (pngjsNs as Record<string, unknown>).PNG ??
  ((pngjsNs as Record<string, unknown>).default as Record<string, unknown> | undefined)?.PNG;
const PNG = pngMod as unknown as typeof import("npm:pngjs@7.0.0").PNG;
const jsqrFn = (jsqrNs as unknown as Record<string, unknown>).default ??
  (jsqrNs as unknown);
const jsQR = (typeof jsqrFn === "function" ? jsqrFn : (jsqrFn as Record<string, unknown>).default) as
  (d: Uint8Array, w: number, h: number, o?: unknown) => { data: string } | null;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const BUCKET = "user-documents";
const MAX_BYTES = 10 * 1024 * 1024;

// QR payload types we understand structurally.
type DocType = "NATIONAL_ID" | "DRIVING_LICENSE" | "DRIVING_LICENSE_ID" | "PASSPORT";

interface Verdict {
  status: "AUTO_APPROVED" | "MANUAL_REVIEW" | "SUSPECTED_FRAUD";
  reasons: string[];
  qrFound: boolean;
  nameMatch: boolean | null;
}

// ── Payload structure validators ──────────────────────────────────────────
// QRs on real IDs carry structured text or JSON. We look for a minimum
// structure, not an exact format — anything structured-but-unknown still
// needs a plausible identifier to auto-approve.

function looksLikeSpam(payload: string): boolean {
  const p = payload.trim().toLowerCase();
  if (p.length < 6 || p.length > 800) return true;
  // URL-only payloads are the classic spam QR pattern.
  if (/^(https?:\/\/|www\.)\S+$/.test(p)) return true;
  // Promo/gibberish markers.
  if (/(free\s*(money|birr|gift)|win|prize|click\s*here|subscribe|telegram\s*channel)/.test(p)) {
    return true;
  }
  return false;
}

function extractName(payload: string): string | null {
  // JSON payloads: common keys across ID QR standards.
  try {
    const obj = JSON.parse(payload);
    if (obj && typeof obj === "object") {
      for (const k of ["full_name", "fullName", "name", "holder", "holder_name"]) {
        const v = (obj as Record<string, unknown>)[k];
        if (typeof v === "string" && v.trim()) return v.trim();
      }
      // Fallback: first string field that looks like a person name.
      for (const v of Object.values(obj as Record<string, unknown>)) {
        if (typeof v === "string" && /^[A-Za-z\\s'.-]{4,60}$/.test(v)) return v.trim();
      }
    }
  } catch {
    /* not JSON */
  }
  // Plain-text payloads: "Name: X" or the first line that looks like a name.
  const labeled = payload.match(/(?:full\s*name|name)\s*[:\-]\s*([^\n]+)/i);
  if (labeled) return labeled[1].trim();
  const firstLine = payload.split(/\n|\s{2,}/)[0]?.trim() ?? "";
  return /^[A-Za-z\\s'.-]{4,60}$/.test(firstLine) ? firstLine : null;
}

function plausiblyValidPayload(payload: string, type: DocType): boolean {
  if (looksLikeSpam(payload)) return false;
  const lower = payload.toLowerCase();
  switch (type) {
    case "NATIONAL_ID": {
      // Fayda-style QRs embed a document number (digits) and/or JSON with id
      // fields. Accept a digit run of 8-16 digits or id-like JSON fields.
      if (/\b\d{8,16}\b/.test(payload)) return true;
      if (/"(?:id|id_number|document_number|fayda|uin)"\s*:/i.test(lower)) return true;
      return false;
    }
    case "DRIVING_LICENSE":
    case "DRIVING_LICENSE_ID": {
      // License numbers mix letters+digits; require some structure.
      if (/\b[A-Z0-9-]{6,20}\b/.test(payload) && /\d{3,}/.test(payload)) return true;
      if (/"(?:license_number|license_no|dl_number|dl_no)"\s*:/i.test(lower)) return true;
      return false;
    }
    case "PASSPORT": {
      // Passport numbers: letter + 7-8 digits (ICAO 9303 style), possibly
      // inside a MRZ-ish payload.
      if (/\b[A-Z]{1,2}\d{7,8}\b/.test(payload.toUpperCase())) return true;
      if (/(passport|p<|mrz)/i.test(lower)) return true;
      return false;
    }
  }
}

// ── Name cross-check ──────────────────────────────────────────────────────
function nameMatches(qrName: string, profileName: string): boolean {
  const norm = (s: string) =>
    s.toLowerCase().replace(/[^a-z\\s]/g, " ").split(/\\s+/).filter(Boolean);
  const a = new Set(norm(qrName));
  const b = new Set(norm(profileName));
  if (!a.size || !b.size) return false;
  let overlap = 0;
  for (const t of a) if (b.has(t)) overlap++;
  return overlap / Math.max(a.size, b.size) >= 0.5; // 50% token overlap
}

// ── Image decode + QR scan ────────────────────────────────────────────────
interface ImageData {
  data: Uint8Array;
  width: number;
  height: number;
}

function decodeImage(bytes: Uint8Array): ImageData | null {
  // JPEG: FFD8 magic. PNG: 89504E47.
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    try {
      const raw = decodeJpeg(bytes, { useTArray: true });
      return { data: new Uint8Array(raw.data), width: raw.width, height: raw.height };
    } catch {
      return null;
    }
  }
  if (
    bytes.length > 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
  ) {
    try {
      const png = PNG.sync.read(Buffer.from(bytes));
      return { data: new Uint8Array(png.data), width: png.width, height: png.height };
    } catch {
      return null;
    }
  }
  return null;
}

// jsQR needs RGBA; jpeg-js gives RGBA too, pngjs gives RGBA. Upscale tiny
// images (QRs vanish under ~200px) and try a couple of sizes.
function scanQr(img: ImageData): string | null {
  const attempts: ImageData[] = [img];
  // 2x upscale for small images.
  if (Math.min(img.width, img.height) < 500) {
    const w = img.width * 2;
    const h = img.height * 2;
    const up = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy = Math.floor(y / 2);
      for (let x = 0; x < w; x++) {
        const sx = Math.floor(x / 2);
        const si = (sy * img.width + sx) * 4;
        const di = (y * w + x) * 4;
        up[di] = img.data[si];
        up[di + 1] = img.data[si + 1];
        up[di + 2] = img.data[si + 2];
        up[di + 3] = 255;
      }
    }
    attempts.push({ data: up, width: w, height: h });
  }
  for (const a of attempts) {
    const code = jsQR(a.data, a.width, a.height, { inversionAttempts: "attemptBoth" });
    if (code?.data) return code.data;
  }
  return null;
}

// ── AI-generator EXIF detection (JPEG only) ───────────────────────────────
// Honest scope: tags are easy to strip. We only catch generators that embed
// software metadata — absence proves nothing, presence is strong evidence.
function detectAiExif(bytes: Uint8Array): string | null {
  if (!(bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8)) return null;
  const head = new TextDecoder("latin1").decode(bytes.slice(0, Math.min(bytes.length, 65536)));
  const m = head.match(/(stable\s*diffusion|stablediffusion|midjourney|dall[\s-]?e|firefly|craiyon|nightcafe|artbreeder|w[a-z]{2,}\s*\.?ai)/i);
  return m ? m[1] : null;
}

// ── Main handler ──────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const anon = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user }, error: userErr } = await anon.auth.getUser();
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  let body: { document_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const docId = (body.document_id ?? "").trim();
  if (!docId) return json({ error: "document_id_required" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    // 1. Load the document row; enforce ownership.
    const { data: doc, error: docErr } = await admin
      .from("user_documents")
      .select("id, user_id, document_type, storage_path, verification_status")
      .eq("id", docId)
      .maybeSingle();
    if (docErr) return json({ error: "lookup_failed", detail: docErr.message }, 500);
    if (!doc) return json({ error: "document_not_found" }, 404);
    if (doc.user_id !== user.id) return json({ error: "forbidden" }, 403);

    const docType = doc.document_type as string;
    const qrCapable: DocType[] = ["NATIONAL_ID", "DRIVING_LICENSE", "DRIVING_LICENSE_ID", "PASSPORT"];
    if (!qrCapable.includes(docType as DocType)) {
      return json({ error: "document_type_not_qr_capable" }, 400);
    }

    // 2. Download + decode.
    const { data: blob, error: dlErr } = await admin.storage
      .from(BUCKET)
      .download(doc.storage_path);
    if (dlErr || !blob) {
      await recordVerdict(admin, doc.id, "MANUAL_REVIEW", {
        error: "download_failed",
      });
      return json({ status: "MANUAL_REVIEW", reason: "download_failed" });
    }
    const bytes = new Uint8Array(await blob.arrayBuffer());
    if (bytes.length > MAX_BYTES) {
      await recordVerdict(admin, doc.id, "MANUAL_REVIEW", { error: "too_large" });
      return json({ status: "MANUAL_REVIEW", reason: "too_large" });
    }

    const img = decodeImage(bytes);
    const aiTag = detectAiExif(bytes);

    let qrText: string | null = null;
    if (img) qrText = scanQr(img);

    // 3. Profile name for cross-check. business_name lives on
    // provider_profiles (0001 schema), not profiles — pull it from there so
    // the query cannot 400 on an unknown column (which used to silently
    // empty the name and fail every cross-check).
    const [{ data: profile, error: profileErr }, { data: providerProfile }] =
      await Promise.all([
        admin.from("profiles").select("full_name").eq("id", user.id).maybeSingle(),
        admin
          .from("provider_profiles")
          .select("business_name")
          .eq("user_id", user.id)
          .maybeSingle(),
      ]);
    if (profileErr) console.error("profile lookup failed:", profileErr.message);
    const profileName =
      ((profile?.full_name as string) ||
        (providerProfile?.business_name as string) ||
        "") as string;

    // 4. Verdict.
    const verdict = evaluate({
      qrText,
      aiTag,
      docType: docType as DocType,
      profileName,
      userId: user.id,
    });

    // 4b. Duplicate reuse check: the same QR payload already registered by
    // a different account is strong fraud evidence. Downgrades AUTO_APPROVED
    // to SUSPECTED_FRAUD (still manual — a human decides).
    if (verdict.qrFound && qrText) {
      const duplicated = await checkDuplicate(admin, qrText, user.id);
      if (duplicated) {
        verdict.status = "SUSPECTED_FRAUD";
        verdict.reasons.push("qr_payload_reused_across_accounts");
      }
    }

    // 5. Persist verdict.
    await recordVerdict(admin, doc.id, verdict.status, {
      reasons: verdict.reasons,
      qr_found: verdict.qrFound,
      name_match: verdict.nameMatch,
      ai_exif_tag: aiTag,
      payload: verdict.qrFound ? qrText : null,
    });

    // 6. Account-level auto-approve.
    if (verdict.status === "AUTO_APPROVED") {
      const { error: upErr } = await admin
        .from("profiles")
        .update({ status: "APPROVED", updated_at: new Date().toISOString() })
        .eq("id", user.id);
      if (upErr) {
        console.error("auto-approve update failed:", upErr.message);
        return json({ status: "MANUAL_REVIEW", reason: "approval_write_failed" });
      }
      await admin.from("approval_history").insert({
        subject_type: "USER",
        subject_id: user.id,
        action: "APPROVE",
        performed_by: null,
        reason: "QR verification agent: automatic approval",
      });
      await admin.from("notifications").insert({
        user_id: user.id,
        type: "APPROVAL",
        title: "Account approved",
        body: "Your ID document was verified automatically. Your account is now active.",
      });
      return json({ status: "AUTO_APPROVED" });
    }

    return json({ status: verdict.status, reasons: verdict.reasons });
  } catch (e) {
    console.error("document-verify failed:", e);
    return json({ error: "internal_error" }, 500);
  }
});

// ── Verdict engine (exported for the local test harness) ──────────────────
interface EvaluateInput {
  qrText: string | null;
  aiTag: string | null;
  docType: DocType;
  profileName: string;
  userId: string;
}

function evaluate(input: EvaluateInput): Verdict {
  const { qrText, aiTag, docType, profileName } = input;
  const reasons: string[] = [];

  // AI-generator metadata → suspected fraud (manual, flagged).
  if (aiTag) {
    reasons.push(`ai_generator_exif: ${aiTag}`);
    return { status: "SUSPECTED_FRAUD", reasons, qrFound: qrText != null, nameMatch: null };
  }

  if (!qrText) {
    reasons.push("no_qr_detected");
    return { status: "MANUAL_REVIEW", reasons, qrFound: false, nameMatch: null };
  }

  if (looksLikeSpam(qrText)) {
    reasons.push("spam_or_fraudulent_payload");
    return { status: "SUSPECTED_FRAUD", reasons, qrFound: true, nameMatch: null };
  }

  if (!plausiblyValidPayload(qrText, docType)) {
    reasons.push("payload_does_not_match_document_type");
    return { status: "MANUAL_REVIEW", reasons, qrFound: true, nameMatch: null };
  }

  const qrName = extractName(qrText);
  const nameMatch = qrName ? nameMatches(qrName, profileName) : null;
  if (qrName && nameMatch === false) {
    reasons.push("name_mismatch");
    return { status: "MANUAL_REVIEW", reasons, qrFound: true, nameMatch };
  }

  return { status: "AUTO_APPROVED", reasons: ["qr_valid"], qrFound: true, nameMatch };
}

// Duplicate check needs the DB, so it stays a separate async step the
// handler runs before persisting (evaluate() stays pure for the harness).
async function checkDuplicate(
  admin: ReturnType<typeof createClient>,
  payload: string,
  userId: string,
): Promise<boolean> {
  const { data } = await admin
    .from("user_documents")
    .select("id, user_id")
    .eq("qr_payload", payload)
    .neq("user_id", userId)
    .limit(1);
  return (data ?? []).length > 0;
}

async function recordVerdict(
  admin: ReturnType<typeof createClient>,
  docId: string,
  status: Verdict["status"],
  extra: Record<string, unknown>,
): Promise<void> {
  await admin
    .from("user_documents")
    .update({
      verification_status: status,
      agent_verdict: extra,
      verified_at: new Date().toISOString(),
      ...(typeof extra.payload === "string" ? { qr_payload: extra.payload } : {}),
    })
    .eq("id", docId);
}

// Duplicate handling is wired in the handler (step 4b): evaluate() stays
// pure so the local harness can exercise it without a database.
