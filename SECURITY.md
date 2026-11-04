# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| `main` branch (latest) | Yes |
| Older commits | No — please update to the latest `main` before reporting |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.** Instead, please use
[private vulnerability reporting](https://github.com/Paksolo/Aura/security/advisories/new)
so we can fix the issue before it is disclosed.

Include in your report:

- A description of the vulnerability and its potential impact
- Steps to reproduce (configuration, payload, or proof of concept)
- The commit or version you tested against
- Any suggested mitigation, if you have one

We will acknowledge your report within 5 business days and keep you updated on
our progress. Once fixed, we will publish a security advisory crediting you
(unless you prefer to stay anonymous).

## Scope

In scope:

- `backend/` — the FastAPI vision server (`POST /assist`), including its
  authentication (`ASSIST_API_KEY`), upload validation, and CORS configuration
- `web/` — the browser test client
- `ios/` — the SwiftUI + Meta Wearables DAT app
- Repository configuration (branch protection, Actions, secrets handling)

Out of scope:

- The Groq / vision-model APIs themselves (report those to the provider)
- Meta glasses hardware/firmware and the Meta AI app
- Vulnerabilities requiring a compromised developer machine or leaked personal
  API keys to exploit

## Handling of Secrets

- API keys live in `backend/.env`, which is git-ignored and must never be
  committed. Secret scanning with push protection is enabled to enforce this.
- If you discover a leaked key in the repository history, report it privately
  (see above) and do not post the key value anywhere.

## Security Measures in Place

- Branch protection on `main` (required reviews, no force pushes/deletions)
- Secret scanning with push protection
- Dependabot alerts and security updates
- CodeQL code scanning on pushes and pull requests
