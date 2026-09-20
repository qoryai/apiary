# The server contract as Apiary implements it (M2)

What the discovery endpoint expects and returns, so the runner side can be written against
it. Anything the contract has not fixed yet is listed under "Assumed" at the end.

## Signed GET

Every request to a contract endpoint carries these headers:

| Header | Value |
|---|---|
| `X-Qory-Access-Key` | the key id, `ak_` and 16 lowercase Crockford base32 characters |
| `X-Qory-Timestamp` | the Unix time in seconds, UTC, as a decimal integer with no fraction |
| `X-Qory-Signature-256` | `sha256=` and the lowercase hex HMAC SHA-256 of the canonical string, keyed with the secret |
| `X-Qory-Contract-Version` | optional; the contract version the runner implements, a decimal integer |
| `User-Agent` | `qory-runner/<version>`; the version is recorded on the key |

The canonical string is three lines joined by `\n` with no trailing newline:

```
GET
/.well-known/qory-configuration?a=1
1700000000
```

1. the method, upper case;
2. the request path, followed by `?` and the query string only when the query string is
   non-empty, both exactly as sent on the wire (no decoding, no re-ordering, no trailing
   slash added or removed);
3. the value of `X-Qory-Timestamp` as sent.

Known answer: the key `test-secret` over `GET\n/.well-known/qory-configuration?x=1\n1700000000`
gives `sha256=e8cc6260e2740e9282f2b45fa8bc590e3afe0e59eb53882b19cdb0f87a613c02`.

The timestamp is accepted when `|server now - timestamp| <= 300` seconds. Either of a key's
two secrets verifies: after a rotation the previous secret keeps working until it is retired
or the key is revoked.

## The discovery document

`GET /.well-known/qory-configuration`, signed as above, answers `200` with
`Content-Type: application/json`:

```json
{
  "version": 1,
  "events": {"url": "https://<public host>/v1/events", "types": ["*"]},
  "run": {"url": "https://<public host>/v1/run-configuration"}
}
```

`<public host>` is the application's public base URL (`PUBLIC_URL`). The `events` and `run`
URLs are named by the document but **do not exist yet**: the events receiver and the run
configuration are later milestones. A runner that fetches them now gets the application's
404. Sections a runner does not know are to be ignored.

## Failure

Every failure is `401` with the body `{"error":"unauthorized"}` and nothing else, whether
the cause is a missing header, an empty header, a key id that is not of the exact form
`ak_` and 16 lowercase Crockford base32 characters (including one that is not valid UTF-8;
such a value is refused before any lookup), a key id that does not exist, a revoked key,
a timestamp that is not an integer, a timestamp outside the window, or a signature that does
not match. The body never says which. Nothing about the request's headers is logged.

On success the key records the time, the runner version from `User-Agent` (when it is of the
form `qory-runner/<version>`) and the contract version from `X-Qory-Contract-Version` (when
present and an integer). What is recorded never decides the answer:

- the runner version is kept to its first 80 characters; a `User-Agent` that is not valid
  UTF-8, or a version with non-printable characters, records no version;
- a contract version outside `0..32767` records no version;
- if recording the use fails, the request still succeeds.

No header value makes the endpoint answer `500`.

## Assumed

The contract has not fixed these; Apiary chose, and the runner should match:

- The hex in the signature is lowercase and compared byte for byte; an uppercase hex
  signature fails.
- The timestamp is compared to the server's clock with a symmetric window of 300 seconds;
  a timestamp in the future is treated like one in the past.
- The path in the canonical string is the raw request target as received, including any
  percent-encoding; nothing is normalised on either side. The query string joins with `?`
  only when non-empty, so `/path` and `/path?` sign differently.
- A header sent twice fails; the first value is not taken and the request is refused.
- `User-Agent` that is not `qory-runner/<version>` is accepted; only the recorded runner
  version is left empty. The same holds for a version that is not printable text, and a
  version longer than 80 characters is recorded truncated.
- `X-Qory-Contract-Version` is a decimal integer in `0..32767`; any other value is accepted
  and ignored, it does not fail the request.
- The discovery path is `/.well-known/qory-configuration`, without a trailing slash, and
  answers JSON only (no content negotiation on `Accept`).
- The public base URL of the document comes from the application's own URL configuration,
  not from the request's `Host` header.
