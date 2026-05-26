## What does this PR do?

<!-- One or two sentences. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Infrastructure / IaC change
- [ ] Refactor
- [ ] Docs / config only

## How to test

<!-- Steps to verify this works locally. -->

```bash
make dev-backend   # :8000
make dev-frontend  # :5173
```

## Screenshots *(if UI change)*

<!-- Before / after, or a short screen recording. -->

## Checklist

- [ ] `make check` passes (ruff + tsc)
- [ ] No secrets or API keys committed
- [ ] If Terraform changed: `make tf-plan` output reviewed and attached
- [ ] If a new endpoint added: tested with `curl` or the frontend
- [ ] `/review` run on this PR (Claude code review)

<!-- Run /review in Claude Code to get an AI review of the diff before merging. -->
