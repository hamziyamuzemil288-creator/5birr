// Local verification harness for the document-verify agent logic.
// Mirrors the exact evaluate()/nameMatches()/payload validators from
// supabase/functions/document-verify/index.ts and exercises them against
// synthetic documents: valid QR payload, spam QR, wrong-type payload,
// name mismatch, no QR, and an AI-generator EXIF tag.
//
// Run: node tools/test/document_verify_harness.mjs
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { execSync } = await import("node:child_process");

// Ensure deps (harness-only, never shipped).
try {
  require.resolve("jsqr");
} catch {
  execSync("npm i --prefix /tmp/agent-harness jsqr@1.4.0 jsqr-fail-stub@npm:jsqr@1.4.0 pngjs@7.0.0 jpeg-js@0.4.4 --no-audit --no-fund", { stdio: "pipe" });
}
const req2 = createRequire("/tmp/agent-harness/package.json");
req2("jsqr"); // warm
const jsQR = (await import("file:///tmp/agent-harness/node_modules/jsqr/dist/jsQR.js")).default;
const { PNG } = req2("pngjs");
const jpeg = req2("jpeg-js");

// ── Mirrored agent logic (keep in sync with the Edge Function) ────────────
function looksLikeSpam(payload) {
  const p = payload.trim().toLowerCase();
  if (p.length < 6 || p.length > 800) return true;
  if (/^(https?:\/\/|www\.)\S+$/.test(p)) return true;
  if (/(free\s*(money|birr|gift)|win|prize|click\s*here|subscribe|telegram\s*channel)/.test(p)) return true;
  return false;
}

function extractName(payload) {
  try {
    const obj = JSON.parse(payload);
    if (obj && typeof obj === "object") {
      for (const k of ["full_name", "fullName", "name", "holder", "holder_name"]) {
        const v = obj[k];
        if (typeof v === "string" && v.trim()) return v.trim();
      }
      for (const v of Object.values(obj)) {
        if (typeof v === "string" && /^[A-Za-z\s'.-]{4,60}$/.test(v)) return v.trim();
      }
    }
  } catch {}
  const labeled = payload.match(/(?:full\s*name|name)\s*[:\-]\s*([^\n]+)/i);
  if (labeled) return labeled[1].trim();
  const firstLine = payload.split(/\n|\s{2,}/)[0]?.trim() ?? "";
  return /^[A-Za-z\s'.-]{4,60}$/.test(firstLine) ? firstLine : null;
}

function plausiblyValidPayload(payload, type) {
  if (looksLikeSpam(payload)) return false;
  const lower = payload.toLowerCase();
  switch (type) {
    case "NATIONAL_ID":
      if (/\b\d{8,16}\b/.test(payload)) return true;
      if (/"(?:id|id_number|document_number|fayda|uin)"\s*:/i.test(lower)) return true;
      return false;
    case "DRIVING_LICENSE":
      if (/\b[A-Z0-9-]{6,20}\b/.test(payload) && /\d{3,}/.test(payload)) return true;
      if (/"(?:license_number|license_no|dl_number|dl_no)"\s*:/i.test(lower)) return true;
      return false;
    case "PASSPORT":
      if (/\b[A-Z]{1,2}\d{7,8}\b/.test(payload.toUpperCase())) return true;
      if (/(passport|p<|mrz)/i.test(lower)) return true;
      return false;
  }
}

function nameMatches(qrName, profileName) {
  const norm = (s) => s.toLowerCase().replace(/[^a-z\s]/g, " ").split(/\s+/).filter(Boolean);
  const a = new Set(norm(qrName));
  const b = new Set(norm(profileName));
  if (!a.size || !b.size) return false;
  let overlap = 0;
  for (const t of a) if (b.has(t)) overlap++;
  return overlap / Math.max(a.size, b.size) >= 0.5;
}

function detectAiExif(bytes) {
  if (!(bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8)) return null;
  const head = Buffer.from(bytes.slice(0, Math.min(bytes.length, 65536))).toString("latin1");
  const m = head.match(/(stable\s*diffusion|stablediffusion|midjourney|dall[\s-]?e|firefly|craiyon|nightcafe|artbreeder|w[a-z]{2,}\s*\.?ai)/i);
  return m ? m[1] : null;
}

function evaluate({ qrText, aiTag, docType, profileName, userId }) {
  const reasons = [];
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

// Duplicate check is DB-side; simulate the downgrade here.
function applyDuplicate(verdict) {
  if (verdict.qrFound && verdict.status === "AUTO_APPROVED") {
    return { ...verdict, status: "SUSPECTED_FRAUD", reasons: [...verdict.reasons, "qr_payload_reused_across_accounts"] };
  }
  return verdict;
}

// ── Image builders (real QR encoding via a tiny embedded QR generator) ────
// Instead of shipping a QR encoder, build a QR through the same jsQR-verified
// path: we construct payloads as QR via 'qrcode' only if present, else fall
// back to painting the payload as an image (which jsQR will NOT read — used
// for the no-QR case). For real QR generation we use the 'qrcode' package.
let QRCode = null;
try {
  QRCode = req2("qrcode");
} catch {
  execSync("npm i --prefix /tmp/agent-harness qrcode@1.5.4 --no-audit --no-fund", { stdio: "pipe" });
  QRCode = req2("qrcode");
}

async function makePngWithQr(payload) {
  const qrBuf = await QRCode.toBuffer(payload, { width: 300, margin: 2, errorCorrectionLevel: "M" });
  const qrPng = PNG.sync.read(qrBuf);
  // Compose onto a 600x400 white document canvas.
  const img = new PNG({ width: 600, height: 400 });
  for (let y = 0; y < 400; y++) {
    for (let x = 0; x < 600; x++) {
      const i = (400 * y + x) * 4;
      img.data[i] = 245; img.data[i + 1] = 245; img.data[i + 2] = 240; img.data[i + 3] = 255;
    }
  }
  PNG.bitblt(qrPng, img, 0, 0, qrPng.width, qrPng.height, 40, 40);
  return PNG.sync.write(img);
}

function makePngPlain() {
  const img = new PNG({ width: 600, height: 400 });
  for (let i = 0; i < img.data.length; i += 4) {
    img.data[i] = 250; img.data[i + 1] = 250; img.data[i + 2] = 245; img.data[i + 3] = 255;
  }
  return PNG.sync.write(img);
}

function makeJpegWithAiTag() {
  const img = new PNG({ width: 400, height: 400 });
  for (let i = 0; i < img.data.length; i += 4) {
    img.data[i] = 200; img.data[i + 1] = 200; img.data[i + 2] = 200; img.data[i + 3] = 255;
  }
  const raw = PNG.sync.write(img);
  // Build a JPEG via jpeg-js encode, then inject an EXIF-looking comment
  // segment before SOS. jpeg-js writes APP0 JFIF; we splice a COM segment
  // with the generator tag (generators write it in APP segments; detection
  // scans the first 64KB regardless of segment type).
  const encoded = jpeg.encode({ data: img.data, width: 400, height: 400 }, 85);
  const marker = Buffer.from([0xff, 0xfe]); // COM segment
  const comment = Buffer.from("stable diffusion v2; prompt=ethiopian id", "latin1");
  const len = Buffer.alloc(2);
  len.writeUInt16BE(comment.length + 2);
  const injectAt = 2; // right after SOI
  const out = Buffer.concat([
    encoded.data.slice(0, injectAt),
    marker, len, comment,
    encoded.data.slice(injectAt),
  ]);
  return new Uint8Array(out);
}

// Decode path mirrored from the agent.
function decodeImage(bytes) {
  if (bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    const raw = jpeg.decode(Buffer.from(bytes), { useTArray: true });
    return { data: new Uint8Array(raw.data), width: raw.width, height: raw.height };
  }
  if (bytes.length > 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const png = PNG.sync.read(Buffer.from(bytes));
    return { data: new Uint8Array(png.data), width: png.width, height: png.height };
  }
  return null;
}

function scanQr(img) {
  const code = jsQR(img.data, img.width, img.height, { inversionAttempts: "attemptBoth" });
  return code?.data ?? null;
}

// ── Tests ─────────────────────────────────────────────────────────────────
let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok  ${name}`); }
  else { fail++; console.error(`FAIL  ${name}${detail ? " — " + detail : ""}`); }
}

const PAYLOAD_OK = JSON.stringify({
  full_name: "Muktar Biya",
  id_number: "48210203994",
  dob: "1999-04-11",
});
const PAYLOAD_SPAM = "https://freemoney-birr.win/claim?u=telegram";
const PAYLOAD_WRONG_TYPE = "CALL 0917 FOR FREE GIFT CARDS"; // spam-ish but short → tests spam path
const PAYLOAD_LICENSE = JSON.stringify({ license_number: "DL-00387123", holder_name: "Muktar Biya" });
const PAYLOAD_MISMATCH = JSON.stringify({ full_name: "Alme Jebessa", id_number: "77210045112" });

console.log("\n[1] Valid National-ID QR → AUTO_APPROVED");
{
  const png = await makePngWithQr(PAYLOAD_OK);
  const img = decodeImage(new Uint8Array(png));
  const qr = scanQr(img);
  check("QR decodes", qr === PAYLOAD_OK, JSON.stringify(qr));
  const v = evaluate({ qrText: qr, aiTag: null, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  check("verdict AUTO_APPROVED", v.status === "AUTO_APPROVED", v.status + " " + JSON.stringify(v.reasons));
  check("name matched", v.nameMatch === true);
}

console.log("\n[2] Spam QR → SUSPECTED_FRAUD (never auto-approve, still manual)");
{
  const png = await makePngWithQr(PAYLOAD_SPAM);
  const qr = scanQr(decodeImage(new Uint8Array(png)));
  const v = evaluate({ qrText: qr, aiTag: null, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  check("verdict SUSPECTED_FRAUD", v.status === "SUSPECTED_FRAUD", v.status);
}

console.log("\n[3] Valid-looking QR, wrong type structure → MANUAL_REVIEW");
{
  // A passport-type payload evaluated against NATIONAL_ID would pass digits;
  // instead use a license payload against PASSPORT (fails both checks there).
  const v = evaluate({ qrText: PAYLOAD_LICENSE, aiTag: null, docType: "PASSPORT", profileName: "Muktar Biya", userId: "u1" });
  check("verdict MANUAL_REVIEW", v.status === "MANUAL_REVIEW", v.status + " " + JSON.stringify(v.reasons));
}

console.log("\n[4] Name mismatch → MANUAL_REVIEW (not fraud — could be transliteration)");
{
  const v = evaluate({ qrText: PAYLOAD_MISMATCH, aiTag: null, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  check("verdict MANUAL_REVIEW", v.status === "MANUAL_REVIEW", v.status);
  check("nameMatch false recorded", v.nameMatch === false);
}

console.log("\n[5] No QR anywhere → MANUAL_REVIEW (never auto-reject)");
{
  const png = makePngPlain();
  const qr = scanQr(decodeImage(new Uint8Array(png)));
  check("no QR decoded", qr === null);
  const v = evaluate({ qrText: qr, aiTag: null, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  check("verdict MANUAL_REVIEW", v.status === "MANUAL_REVIEW", v.status);
}

console.log("\n[6] AI-generator EXIF → SUSPECTED_FRAUD");
{
  const bytes = makeJpegWithAiTag();
  const tag = detectAiExif(bytes);
  check("EXIF tag detected", tag !== null, String(tag));
  const v = evaluate({ qrText: null, aiTag: tag, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  check("verdict SUSPECTED_FRAUD", v.status === "SUSPECTED_FRAUD", v.status);
}

console.log("\n[7] Duplicate payload across accounts → downgraded to SUSPECTED_FRAUD");
{
  const v = evaluate({ qrText: PAYLOAD_OK, aiTag: null, docType: "NATIONAL_ID", profileName: "Muktar Biya", userId: "u1" });
  const v2 = applyDuplicate(v);
  check("downgraded", v2.status === "SUSPECTED_FRAUD", v2.status);
}

console.log("\n[8] Driving License QR valid → AUTO_APPROVED");
{
  const png = await makePngWithQr(PAYLOAD_LICENSE);
  const qr = scanQr(decodeImage(new Uint8Array(png)));
  const v = evaluate({ qrText: qr, aiTag: null, docType: "DRIVING_LICENSE", profileName: "Muktar Biya", userId: "u1" });
  check("verdict AUTO_APPROVED", v.status === "AUTO_APPROVED", v.status + " " + JSON.stringify(v.reasons));
}

console.log("\n[9] Passport QR (ICAO number) → AUTO_APPROVED");
{
  const png = await makePngWithQr("EP1234567");
  const qr = scanQr(decodeImage(new Uint8Array(png)));
  const v = evaluate({ qrText: qr, aiTag: null, docType: "PASSPORT", profileName: "Muktar Biya", userId: "u1" });
  check("verdict AUTO_APPROVED", v.status === "AUTO_APPROVED", v.status + " " + JSON.stringify(v.reasons));
}

console.log("\n[10] decodeImage round-trips a JPEG (camera-realistic path)");
{
  const png = await makePngWithQr(PAYLOAD_OK);
  const asJpeg = jpeg.encode(PNG.sync.read(png), 80);
  const img = decodeImage(new Uint8Array(asJpeg.data));
  const qr = scanQr(img);
  check("QR survives JPEG re-encode", qr === PAYLOAD_OK, JSON.stringify(qr));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
