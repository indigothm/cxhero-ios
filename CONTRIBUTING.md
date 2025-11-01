# Contributing to CXHero

Thanks for your interest in improving CXHero! This project welcomes community contributions. To keep licensing clear for everyone (including contributors and their employers), please read this document before opening a pull request.

## Quick Start
- Fork this repository and create a feature branch.
- Run tests locally (SwiftPM): `swift test`.
- Commit with sign‑off: `git commit -s -m "feat: your change"`.
- Open a pull request.

## Developer Certificate of Origin (DCO)
We use the Developer Certificate of Origin (DCO) to confirm you have the right to contribute. Every commit must be signed off using the `-s` flag:

```
Signed-off-by: Your Name <your.email@example.com>
```

Git adds this line automatically when you commit with `-s`:

```
git commit -s -m "fix: correct behavior"
```

If you forgot to sign off, you can amend the last commit:

```
git commit --amend -s --no-edit
```

Or re‑sign a series of commits (interactive rebase):

```
git rebase --exec 'git commit --amend -s --no-edit' -i main
```

By signing off, you certify the DCO: that you wrote the code or otherwise have the right to submit it under the project’s license, including any necessary permissions from your employer.

## Licensing of Contributions
This repository is published under the CXHero Non‑Commercial License (NCL). To keep the project’s non‑commercial distribution healthy while enabling case‑by‑case commercial licensing, contributors agree to the following when submitting a PR:

1) Inbound = Outbound
- You (and/or your employer) license your contribution to the project under the same license the project uses (the CXHero NCL). This allows us to include your contribution in the publicly available, non‑commercial package.

2) Commercial Relicensing Grant (CLA‑lite)
- In addition to the above, you grant the CXHero maintainers a perpetual, worldwide, non‑exclusive, royalty‑free license to use, reproduce, modify, sublicense, and relicense your contribution as part of the CXHero project, including in commercial licenses granted on a case‑by‑case basis.
- You (and/or your employer) retain copyright in your contribution. This grant does not transfer ownership.

3) Employer Contributions
- If you contribute as part of your employment, ensure you are authorized to grant the above rights. Your DCO sign‑off confirms you have obtained all necessary permissions.

4) Patents
- This project’s public license does not include a patent grant. Do not contribute code that requires a third‑party patent license we cannot obtain. If your contribution may implicate patents you control, disclose that context in the PR so maintainers can evaluate commercial‑license implications.

## Code Style & Scope
- Keep changes focused on the issue/feature; avoid unrelated refactors.
- Follow existing code structure and naming.
- Add or update tests when changing behavior.
- Update documentation (README, comments) when needed.

## Security & Privacy
- Do not include secrets in code or tests.
- Prefer local‑first and minimal data collection; keep telemetry opt‑in at the app layer.

## Communication
- Open issues for bugs or proposals.
- PR descriptions should explain the problem, solution, and any trade‑offs.

By opening a pull request, you confirm your contribution complies with the DCO and the Licensing of Contributions section above.

