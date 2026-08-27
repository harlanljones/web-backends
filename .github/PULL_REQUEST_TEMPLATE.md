## Summary

What this PR changes and why.

## Checklist

- [ ] The framework reference (if changed) still implements all four workload
      endpoints + `/health` + `/metrics` per `contracts/openapi.yaml`.
- [ ] `bench/conformance/run.py` passes 9/9 against a live Postgres (if the
      change touches a reference implementation).
- [ ] Shell scripts pass `bash -n`; Python passes `python3 -m py_compile`.
- [ ] Lockfiles are committed and unchanged unless dependencies changed.
- [ ] No secrets, `.env`, build artifacts, or `runs/` output committed.
- [ ] Documentation updated (README, `docs/`, per-framework `README.md`) where
      behavior changed.

## Reproduction / evidence

Commands you ran and the result (e.g. conformance output, a trial summary).
