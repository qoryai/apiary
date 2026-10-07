// An access key made in the browser, with WebCrypto's Ed25519: the pure part of the
// GenerateKey hook (generate_key.js), with no page in it, so that `node --test` runs it
// under Node's own WebCrypto (assets/js/test/key_pair.test.mjs).
//
// The secret is the runner contract's (contracts/runner/v1, README "access key"): `qak_`
// and the key's 32-byte Ed25519 seed in base64url without padding, 47 characters. That
// seed, so encoded, is exactly the `d` of the private key's JWK (RFC 8037), and the public
// key Qory stores is the JWK's `x`, the 32 raw bytes in base64url. Neither is re-encoded.
//
// Only the public key ever leaves this file: `generate` pushes the one event
// `generate_key` with `{key: {label, allow_secrets, public_key}}`, and hands the secret
// back to its caller alone, which shows it once and drops it. Nothing here logs, stores
// or puts a value in an error: a failure is a `KeyPairError` whose `kind` says which, and
// it carries no other value (no `cause`).
//
// Browser support, from MDN's browser-compat-data (api/SubtleCrypto.json, the "ed25519"
// entries of generateKey, importKey, exportKey, sign and verify, read 2026-10-07): Chrome
// and Edge 137, Firefox 129, Safari and Safari on iOS 17 (Safari signs with randomised
// rather than deterministic signatures, which the round trip below does not depend on).
// All need a secure context: on plain HTTP `crypto.subtle` is missing.

export const EVENT = "generate_key"

const ALGORITHM = {name: "Ed25519"}
const SECRET_PREFIX = "qak_"
const KEY_BYTES = 32

// What the round trip signs: any bytes do, these mean nothing.
const CHECK_MESSAGE = Uint8Array.from({length: 32}, (_, i) => i)

// A failure, by kind only: "insecure" (no secure context), "unsupported" (no Ed25519,
// or one whose keys fail the checks below).
export class KeyPairError extends Error {
  constructor(kind) {
    super(kind)
    this.name = "KeyPairError"
    this.kind = kind
  }
}

// Whether this browser can make a key here: "ok", "insecure" or "unsupported". It makes
// one throw-away pair, as a key is made, to catch an implementation that names Ed25519
// but cannot generate it; the pair is never exported. It never throws.
export async function checkSupport(subtle, isSecure) {
  if (isSecure !== true) return "insecure"
  if (!subtle || typeof subtle.generateKey !== "function") return "unsupported"
  try {
    const pair = await subtle.generateKey(ALGORITHM, true, ["sign", "verify"])
    return pair && pair.privateKey && pair.publicKey ? "ok" : "unsupported"
  } catch (_e) {
    return "unsupported"
  }
}

// A new key: `{secret, publicKey}`, the secret in the contract's form and the public key
// in base64url. Before it answers it checks that the browser's export is the one the
// contract reads: `d` and `x` are 32 bytes in canonical base64url, `x` is the raw public
// key, `x` is not `d`, and the private key imported back from `d` (and `x`) signs what the
// public key verifies, so the secret shown is the one that matches the public key sent.
// Any failure is KeyPairError("unsupported"). The CryptoKeys go out of scope here.
export async function makeKey(subtle) {
  let made
  try {
    made = await encode(subtle)
  } catch (_e) {
    made = null
  }
  if (!made) throw new KeyPairError("unsupported")
  return made
}

async function encode(subtle) {
  const pair = await subtle.generateKey(ALGORITHM, true, ["sign", "verify"])
  if (!pair || !pair.privateKey || !pair.publicKey) return null

  const jwk = await subtle.exportKey("jwk", pair.privateKey)
  if (!jwk || jwk.kty !== "OKP" || jwk.crv !== "Ed25519") return null
  const d = decode(jwk.d)
  const x = decode(jwk.x)
  if (!d || d.length !== KEY_BYTES || !x || x.length !== KEY_BYTES) return null
  if (jwk.x === jwk.d || equalBytes(d, x)) return null

  const raw = new Uint8Array(await subtle.exportKey("raw", pair.publicKey))
  if (raw.length !== KEY_BYTES || !equalBytes(raw, x)) return null

  const signer = await subtle.importKey(
    "jwk",
    {kty: "OKP", crv: "Ed25519", d: jwk.d, x: jwk.x},
    ALGORITHM,
    false,
    ["sign"],
  )
  const signature = await subtle.sign(ALGORITHM, signer, CHECK_MESSAGE)
  const verified = await subtle.verify(ALGORITHM, pair.publicKey, signature, CHECK_MESSAGE)
  if (verified !== true) return null

  return {secret: SECRET_PREFIX + jwk.d, publicKey: jwk.x}
}

// Makes a key and pushes the one event that registers it, `push(EVENT, {key: {label,
// allow_secrets, public_key}})`, exactly once, with strings only. Answers `{secret,
// publicKey, reply}`, `reply` being what `push` returned (LiveView's promise of the
// server's reply), not awaited: the caller holds the secret before any reply can arrive.
// A key that cannot be made is KeyPairError("unsupported"), and nothing is pushed.
export async function generate({subtle, label, allowSecrets, push}) {
  const {secret, publicKey} = await makeKey(subtle)
  const reply = push(EVENT, {
    key: {
      label: String(label ?? ""),
      allow_secrets: String(allowSecrets ?? ""),
      public_key: publicKey,
    },
  })
  return {secret, publicKey, reply}
}

// Base64url without padding, as the contract writes keys.
export function encodeBase64url(bytes) {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")
}

// Strict, as the runner decodes (Go's RawURLEncoding.Strict()): the base64url alphabet,
// no padding, and no stray bits in the last character. Anything else is null.
export function decodeBase64url(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) {
    return null
  }
  let binary
  try {
    binary = atob(text.replaceAll("-", "+").replaceAll("_", "/"))
  } catch (_e) {
    return null
  }
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0))
  return encodeBase64url(bytes) === text ? bytes : null
}

const decode = decodeBase64url

function equalBytes(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}

// What the hook does with the secret's slot (generate_key.js `fill`), from what it knows:
// `held`, the `{secret, publicKey}` it holds or null; `filled`, the public key whose secret
// it last wrote into a slot, or null; `slotKey`, the slot's `data-public-key`; `shown`,
// whether the slot's value holds text. One of:
//
// - "fill": the held secret is this slot's key's; write it.
// - "wipe": the slot shows a secret that is not this key's (its public key changed under
//   it); empty it, drop anything held, and say the secret is gone.
// - "gone": the slot is empty and nothing held is for it; drop anything held, and say the
//   secret is gone.
// - "keep": the slot shows this key's secret; leave it.
export function slotStep({held, filled, slotKey, shown}) {
  if (held && typeof slotKey === "string" && held.publicKey === slotKey) return "fill"
  if (shown && filled !== slotKey) return "wipe"
  if (!shown) return "gone"
  return "keep"
}
