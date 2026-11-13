# Security policy

This page says how to report a vulnerability in `erlang_wasm`, and what counts
as one. For the threat model and how to run untrusted code safely, read
[docs/security.md](docs/security.md).

## Report a vulnerability privately

Use the repository's **Security** tab, then **Report a vulnerability**. The
report reaches the maintainer privately, as a draft security advisory, and
stays private until a fix is released.

Do not open a public issue, a pull request or a discussion for a
vulnerability: that publishes it before it is fixed.

Include:

- the version or commit you tested
- what a guest module or a network client can do that it should not
- the smallest reproduction you have: a module, the host setup, and the calls

## Supported versions

Security fixes go to the latest release line. Upgrade to the newest release
before reporting, if you can.

## What counts

A vulnerability is something a guest module or a network client can do
against a host set up as [docs/security.md](docs/security.md) describes:

- reach host code, files or the network beyond what was granted
- make the node use memory, processes or time past a limit that should hold
- crash the node, or another tenant's instance

Running out of memory or time under limits the embedder did not set is not a
vulnerability. The runtime's limits are opted into, and
[docs/security.md](docs/security.md) lists every one to set before running
code you do not trust.
