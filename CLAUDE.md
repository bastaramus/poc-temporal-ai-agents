# Repository conventions for AI assistants

## Strict rule: anonymization for public publishing

This repo is intended to be published publicly. Treat that as a hard constraint
on every file you create or edit, including the prompt log, SUBMISSION
documents, READMEs, comments, commit messages, and tracing entries.

**Never write any of the following into any file:**

- The hiring company's name, product names, domains, or email addresses (in any
  casing or punctuation), nor any obvious paraphrase that would identify them
  (e.g. "the KYB-infra startup in New York"). If a source document names the
  company, replace it with the placeholder `[Company]` when quoting or
  referencing it.
- Names of any third-party individuals associated with the company (recruiters,
  hiring managers, employees). Replace with `[referrer]`, `[reviewer]`, etc.
- Vendor-specific URLs from the source brief (replace with `example.com` /
  `example.ai`).

The user's own name, location, and GitHub-account-level identity may remain —
this is their repo published under their identity.

If the user pastes raw text containing forbidden identifiers, polish it through
the same redaction filter before persisting it.

When in doubt, redact and ask. A leaked company name in a public repo is much
worse than an over-redacted log entry.

