# Security

## Reporting a vulnerability

Write to **info@8wonders.de**. Do not open a public issue or pull request for it.

Say what you found, the version (the `version` field of `/health`), and how to see it
happen: the configuration, the request, and what happened that should not have. Take any
secret out of what you send.

You get an answer within three working days. We tell you what we found, fix what is a
vulnerability in a new release, and publish an advisory that credits you unless you
would rather it did not.

## Supported versions

The latest release. Below 1.0 a fix is a new release and is not carried back to an
earlier one.

## What is a vulnerability here

- A request without a valid signature, or signed by a revoked access key, is answered as
  if it were signed: the discovery document, the events endpoint and the run
  configuration serve only a request signed by an active node key, one not revoked.
- An enrolment code works when it should not. A key enrolled with a valid code is active
  at once: the code is the approval, given by the owner or admin who made it. So it is a
  vulnerability if a code enrols a key after its maker stopped being an owner or an admin
  of its workspace; if it enrols a second key once used (the same machine asking again
  with the same public key gets that same key back, and nothing changes); if it works
  after it expired or was cancelled; or if it puts a key on another node than its own.
- A row of one organisation is readable or writable from another: a page, a query or an
  endpoint that does not scope by the organisation and the workspace of the caller.
- The server's signing key, `APIARY_SIGNING_SECRET`, leaves the application in any form,
  or an enrolment code leaves it other than on the one page that made it: in a log line,
  an event, an email, another page, or in clear in the database.
- An answer carries a valid signature for a request it does not answer.
- A member does what only an owner may, or the last owner of an organisation can be
  removed.
- Sign-in, confirmation, password reset or an invitation link can be used by someone the
  link was not sent to.
- A page of the console runs a script that is not the console's own: one without the
  request's nonce, an `on…=` attribute or a `javascript:` address, while the page's
  `Content-Security-Policy` header reaches the browser as the release sent it.

The wall, the gateway and the signed delivery on the machine are
[Forager](https://github.com/qoryai/forager)'s, and so is its
[security policy](https://github.com/qoryai/forager/blob/main/SECURITY.md). Reports about
them come to the same address.

If you are not sure whether something counts, write anyway.
