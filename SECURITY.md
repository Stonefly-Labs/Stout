# Security Policy

Security is a first-class, non-negotiable priority for Stout. This library handles
secrets (Application Insights connection strings, instrumentation keys, and access
tokens) and runs inside customers' production services, so we treat vulnerability
reports with corresponding seriousness.

## Reporting a vulnerability

**Please do not open a public issue, discussion, or pull request for a security
vulnerability.** Public disclosure before a fix is available puts every user at risk.

Instead, use **GitHub private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with as much detail as you can: affected version(s), a
   description of the issue, reproduction steps or a proof of concept, and the
   potential impact.

This opens a private channel visible only to the maintainers, where we can discuss,
validate, and coordinate a fix and disclosure with you.

## What to expect

Stout is **pre-1.0** software under active development. During this phase:

- We aim to **acknowledge** a report within a few business days.
- We will keep you updated as we investigate and work on a fix.
- Only the latest release line is supported for security fixes; there are no
  long-term-support branches yet.
- Once a fix is ready, we will coordinate a release and public disclosure (and,
  where appropriate, a GitHub Security Advisory with credit to the reporter, unless
  you prefer to remain anonymous).

## Handling of secrets

Stout is designed so that connection strings, instrumentation keys, and tokens are
never written to logs, error messages, or the library's own telemetry. If you find a
case where a secret can leak, please report it through the private channel above — we
consider secret leakage a security issue.

Thank you for helping keep Stout and its users safe.
