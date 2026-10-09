// The browser's access key (assets/js/hooks/key_pair.js), under Node's own WebCrypto:
// `node --test assets/js/test/` (no npm). It proves the secret's form against Forager's
// contract, and that what the browser sends Qory is the label and the public key, never
// the secret.

import {test} from "node:test"
import assert from "node:assert/strict"
import {webcrypto} from "node:crypto"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"

import {
  EVENT,
  KeyPairError,
  checkSupport,
  decodeBase64url,
  encodeBase64url,
  generate,
  makeKey,
  slotShows,
  slotStep,
} from "../hooks/key_pair.js"

const subtle = webcrypto.subtle
const ED25519 = {name: "Ed25519"}

// The contract's fixture access key, copied from Forager at a08473d,
// contracts/forager/v1/fixtures/known-answers/keys.json, "access_key": its seed is the
// bytes 1 to 32. qory refuses this secret and the server refuses this key.
const FIXTURE = {
  seed: Uint8Array.from({length: 32}, (_, i) => i + 1),
  secret: "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
  public_key: "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ",
  fingerprint: "ZbYGc9btiEvwHCwiLYKtoA",
}

// RFC 8410: an Ed25519 private key as PKCS#8 is this prefix and its 32-byte seed.
const PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
])

async function pairFromSeed(seed) {
  const pkcs8 = new Uint8Array([...PKCS8_PREFIX, ...seed])
  const privateKey = await subtle.importKey("pkcs8", pkcs8, ED25519, true, ["sign"])
  const {x} = await subtle.exportKey("jwk", privateKey)
  const publicKey = await subtle.importKey("raw", decodeBase64url(x), ED25519, true, ["verify"])
  return {privateKey, publicKey}
}

// WebCrypto whose generateKey answers `pair`, or records what it made.
function subtleWith(overrides) {
  return {
    generateKey: (...args) => subtle.generateKey(...args),
    exportKey: (...args) => subtle.exportKey(...args),
    importKey: (...args) => subtle.importKey(...args),
    sign: (...args) => subtle.sign(...args),
    verify: (...args) => subtle.verify(...args),
    ...overrides,
  }
}

function recordingPush() {
  const calls = []
  const reply = Promise.resolve({key_id: "ak_example000000000"})
  const push = (event, payload) => {
    calls.push({event, payload})
    return reply
  }
  return {calls, push, reply}
}

async function fingerprint(publicKey) {
  const digest = new Uint8Array(await subtle.digest("SHA-256", decodeBase64url(publicKey)))
  return encodeBase64url(digest.slice(0, 16))
}

// Every way the seed could be written out: base64url, standard base64 (padded or not),
// hex in either case, and the secret itself.
function seedForms(seed) {
  const b64 = Buffer.from(seed).toString("base64")
  const hex = Buffer.from(seed).toString("hex")
  return [
    encodeBase64url(seed),
    b64,
    b64.replace(/=+$/, ""),
    hex,
    hex.toUpperCase(),
    "qak_" + encodeBase64url(seed),
  ]
}

function assertCarriesNoSecret(json, seed) {
  assert.ok(!/qak_/i.test(json), "the payload holds qak_")
  for (const form of seedForms(seed)) {
    assert.ok(!json.includes(form), "the payload holds the seed")
  }
}

test("the contract's known answer: the fixture seed gives keys.json's secret, public key and fingerprint", async () => {
  const pair = await pairFromSeed(FIXTURE.seed)
  const key = await makeKey(subtleWith({generateKey: async () => pair}))

  assert.equal(key.secret, FIXTURE.secret)
  assert.equal(key.secret.length, 47)
  assert.equal(key.publicKey, FIXTURE.public_key)
  assert.equal(await fingerprint(key.publicKey), FIXTURE.fingerprint)
  assert.deepEqual(Object.keys(key).sort(), ["publicKey", "secret"])
})

test("generate pushes generate_key once, with the label and the public key only", async () => {
  const pair = await pairFromSeed(FIXTURE.seed)
  const {calls, push, reply} = recordingPush()

  const made = await generate({
    subtle: subtleWith({generateKey: async () => pair}),
    label: "build-01",
    push,
  })

  assert.equal(calls.length, 1)
  const [{event, payload}] = calls
  assert.equal(event, "generate_key")
  assert.equal(EVENT, "generate_key")
  assert.deepEqual(Object.keys(payload), ["key"])
  assert.deepEqual(Object.keys(payload.key).sort(), ["label", "public_key"])
  assert.deepEqual(payload.key, {
    label: "build-01",
    public_key: FIXTURE.public_key,
  })
  for (const value of Object.values(payload.key)) assert.equal(typeof value, "string")

  const raw = new Uint8Array(await subtle.exportKey("raw", pair.publicKey))
  assert.equal(payload.key.public_key, encodeBase64url(raw))

  assertCarriesNoSecret(JSON.stringify(payload), FIXTURE.seed)
  assertCarriesNoSecret(JSON.stringify(calls), FIXTURE.seed)

  // The secret goes back to the caller alone, with what push answered.
  assert.equal(made.secret, FIXTURE.secret)
  assert.equal(made.publicKey, FIXTURE.public_key)
  assert.equal(made.reply, reply)
})

test("generate sends no secret for fresh keys either, and strings for whatever it is given", async () => {
  for (let i = 0; i < 10; i++) {
    const {calls, push} = recordingPush()
    const made = await generate({subtle, label: "spot-runners", push})

    assert.equal(calls.length, 1)
    assert.deepEqual(calls[0].payload.key, {
      label: "spot-runners",
      public_key: made.publicKey,
    })
    const seed = decodeBase64url(made.secret.slice("qak_".length))
    assert.equal(seed.length, 32)
    assertCarriesNoSecret(JSON.stringify(calls), seed)
  }
})

test("50 fresh keys: d is 43 characters of base64url, x is not d, x is the raw public key", async () => {
  const seen = new Set()
  for (let i = 0; i < 50; i++) {
    let made
    const recording = subtleWith({
      generateKey: async (...args) => (made = await subtle.generateKey(...args)),
    })
    const key = await makeKey(recording)

    assert.match(key.secret, /^qak_[A-Za-z0-9_-]{43}$/)
    const d = key.secret.slice("qak_".length)
    assert.equal(d.length, 43)
    assert.ok(!d.includes("="))
    assert.match(key.publicKey, /^[A-Za-z0-9_-]{43}$/)
    assert.notEqual(key.publicKey, d)

    const raw = new Uint8Array(await subtle.exportKey("raw", made.publicKey))
    assert.equal(key.publicKey, encodeBase64url(raw))

    // The secret is the seed of that very key: the key made again from it has this x.
    const again = await pairFromSeed(decodeBase64url(d))
    const againRaw = new Uint8Array(await subtle.exportKey("raw", again.publicKey))
    assert.equal(encodeBase64url(againRaw), key.publicKey)

    assert.ok(!seen.has(d), "a seed came twice")
    seen.add(d)
  }
})

test("checkSupport: a secure context with Ed25519 is ok; else it says which", async () => {
  assert.equal(await checkSupport(subtle, true), "ok")
  assert.equal(await checkSupport(subtle, false), "insecure")
  assert.equal(await checkSupport(undefined, false), "insecure")
  assert.equal(await checkSupport(undefined, true), "unsupported")
  const refusing = subtleWith({
    generateKey: async () => {
      throw new DOMException("Unrecognized name.", "NotSupportedError")
    },
  })
  assert.equal(await checkSupport(refusing, true), "unsupported")
})

test("a browser whose key fails a check is unsupported, says no value, and pushes nothing", async () => {
  const fixture = await pairFromSeed(FIXTURE.seed)
  const other = await pairFromSeed(Uint8Array.from({length: 32}, (_, i) => 255 - i))

  const broken = {
    "no Ed25519": subtleWith({
      generateKey: async () => {
        throw new DOMException("Unrecognized name.", "NotSupportedError")
      },
    }),
    "a JWK of another curve": subtleWith({
      generateKey: async () => fixture,
      exportKey: async (format, key) => {
        const out = await subtle.exportKey(format, key)
        return format === "jwk" ? {...out, crv: "X25519"} : out
      },
    }),
    "a padded d": subtleWith({
      generateKey: async () => fixture,
      exportKey: async (format, key) => {
        const out = await subtle.exportKey(format, key)
        return format === "jwk" ? {...out, d: out.d + "="} : out
      },
    }),
    "a raw public key that is not x": subtleWith({
      generateKey: async () => ({privateKey: fixture.privateKey, publicKey: other.publicKey}),
    }),
    "x equal to d": subtleWith({
      generateKey: async () => fixture,
      exportKey: async (format, key) => {
        const out = await subtle.exportKey(format, key)
        return format === "jwk" ? {...out, x: out.d} : out
      },
    }),
    "a failed round trip": subtleWith({
      generateKey: async () => fixture,
      verify: async () => false,
    }),
  }

  for (const [why, brokenSubtle] of Object.entries(broken)) {
    await assert.rejects(
      makeKey(brokenSubtle),
      e => {
        assert.ok(e instanceof KeyPairError, why)
        assert.equal(e.kind, "unsupported", why)
        assert.equal(e.message, "unsupported", why)
        assert.equal(e.cause, undefined, why)
        return true
      },
      why,
    )

    const {calls, push} = recordingPush()
    await assert.rejects(
      generate({subtle: brokenSubtle, label: "build-01", push}),
      KeyPairError,
    )
    assert.equal(calls.length, 0, why)
  }
})

test("base64url is decoded strictly, as Forager does", () => {
  assert.deepEqual(decodeBase64url(FIXTURE.secret.slice(4)), FIXTURE.seed)
  assert.equal(encodeBase64url(FIXTURE.seed), FIXTURE.secret.slice(4))
  // Padding, the standard alphabet, and stray bits in the last character.
  assert.equal(decodeBase64url(FIXTURE.secret.slice(4) + "="), null)
  assert.equal(decodeBase64url("AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyB"), null)
  assert.equal(decodeBase64url("ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"), null)
  assert.equal(decodeBase64url(undefined), null)
})

test("the secret's slot shows only the secret of its own key", () => {
  const a = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
  const b = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
  const heldA = {secret: "qak_a", publicKey: a}

  // Made on this page: the slot for its key is filled; another key's slot is not.
  assert.equal(slotStep({held: heldA, filled: null, slotKey: a, shown: false}), "fill")
  assert.equal(slotStep({held: heldA, filled: null, slotKey: b, shown: false}), "gone")
  // Filled, and patched again on the same key's page: kept.
  assert.equal(slotStep({held: null, filled: a, slotKey: a, shown: true}), "keep")
  // Opened again, or reloaded: nothing held, so the secret is gone.
  assert.equal(slotStep({held: null, filled: null, slotKey: a, shown: false}), "gone")
  // A history jump from B's page to A's, the slot keeping B's secret under A's public key:
  // emptied, and said gone.
  assert.equal(slotStep({held: null, filled: b, slotKey: a, shown: true}), "wipe")
  // A shown value the hook never wrote: emptied too.
  assert.equal(slotStep({held: null, filled: null, slotKey: a, shown: true}), "wipe")
  // A slot with no public key is filled by nothing.
  assert.equal(slotStep({held: heldA, filled: null, slotKey: null, shown: false}), "gone")
})

test("the page never says the secret is not shown beside it, and a reconnect keeps it", () => {
  const a = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
  const b = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
  const heldA = {secret: "qak_a", publicKey: a}
  const says = state => slotShows(slotStep(state))

  // Made here: the secret, the notice, its Copy and the note beside Done; not the gone line.
  assert.deepEqual(says({held: heldA, filled: null, slotKey: a, shown: false}), {
    secret: true,
    gone: false,
  })
  // Joined again after a dropped connection: the slot kept the secret the hook wrote, so
  // the page still shows it, says it is shown once, and does not say it is gone.
  assert.deepEqual(says({held: null, filled: a, slotKey: a, shown: true}), {
    secret: true,
    gone: false,
  })
  // Opened again, or reloaded: nothing held for this key, the gone line alone.
  assert.deepEqual(says({held: null, filled: null, slotKey: a, shown: false}), {
    secret: false,
    gone: true,
  })
  // Another key's secret under this key's slot, or one the hook never wrote: gone alone.
  assert.deepEqual(says({held: null, filled: b, slotKey: a, shown: true}), {
    secret: false,
    gone: true,
  })
  assert.deepEqual(says({held: null, filled: null, slotKey: a, shown: true}), {
    secret: false,
    gone: true,
  })

  // Never both, whatever the step.
  for (const step of ["fill", "keep", "wipe", "gone"]) {
    const {secret, gone} = slotShows(step)
    assert.notEqual(secret, gone, step)
  }
})

test("the hook leaves the slot alone on a reconnect, and says again what it shows", () => {
  const source = readFileSync(
    fileURLToPath(new URL("../hooks/generate_key.js", import.meta.url)),
    "utf8",
  )
  const body = name => {
    const start = source.indexOf(`  ${name}() {`)
    assert.notEqual(start, -1, name)
    return source.slice(start, source.indexOf("\n  },", start))
  }
  // A dropped connection loses only a key still on its way, never the shown secret.
  assert.doesNotMatch(body("disconnected"), /clear\(|textContent/)
  assert.doesNotMatch(body("reconnected"), /clear\(|textContent/)
  assert.match(body("reconnected"), /this\.fill\(\)/)
})

test("the hook logs nothing, stores nothing and writes the secret as text only", () => {
  for (const file of ["../hooks/key_pair.js", "../hooks/generate_key.js"]) {
    const source = readFileSync(fileURLToPath(new URL(file, import.meta.url)), "utf8")
    assert.doesNotMatch(source, /\bconsole\s*\./, file)
    assert.doesNotMatch(source, /localStorage|sessionStorage|indexedDB|document\.cookie/, file)
    assert.doesNotMatch(source, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/, file)
    assert.doesNotMatch(source, /\bwindow\.[A-Za-z_$][\w$]*\s*=[^=]/, file)
  }
})
