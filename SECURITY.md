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

- A request without a valid signature, or with a revoked access key, is answered as if it
  were signed: the discovery document, and later the receiver and the run configuration,
  are served only to a request the hive's secret signed.
- A row of one organisation is readable or writable from another: a page, a query or an
  endpoint that does not scope by the organisation and the hive of the caller.
- An access key's secret leaves the application other than in the one reveal after it is
  created or rotated: in a log line, an event, an email, a page, or in clear in the
  database.
- A member does what only an owner may, or the last owner of an organisation can be
  removed.
- Sign-in, confirmation, password reset or an invitation link can be used by someone the
  link was not sent to.

The wall, the proxy and the signed delivery on the machine are the
[runner](https://github.com/qoryai/runner)'s, and so is its
[security policy](https://github.com/qoryai/runner/blob/main/SECURITY.md). Reports about
them come to the same address.

If you are not sure whether something counts, write anyway.
