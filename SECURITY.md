# Security Policy

## Reporting a Vulnerability

PullPing stores GitHub access tokens in your login keychain and uses them to call the GitHub
API, so security reports are taken seriously. Please **do not** open a public issue for
security problems.

Instead, use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on this repository).

You'll get an acknowledgement within a few days. Once a fix is available it will be released
and the report disclosed, with credit unless you prefer otherwise.

If you think a token has leaked (in an issue, a log or a screenshot), revoke it right away on
GitHub under **Settings → Developer settings → Personal access tokens**.

## Scope

PullPing runs on your Mac and talks only to `api.github.com` and `github.com`. It requests no
elevated privileges and has no analytics. Relevant areas:

- **Tokens:** stored as generic-password items in the login keychain through `/usr/bin/security`;
  never written to disk elsewhere, never logged.
- **Network:** the GraphQL client and the optional OAuth device flow.
- **`pullping://` links:** the URL handler accepts only `open`, `open?pr=`, `refresh` and
  `settings`, and never acts on anything but PullPing's own state.
- **Local data:** pull request titles and activity are kept in
  `~/Library/Application Support/PullPing`; delete the folder to remove them.
