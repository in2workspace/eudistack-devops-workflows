# eudistack-devops-workflows

Reusable CI/CD workflows, deployment templates, and automation scripts for EUDIStack services.

## Reusable workflows

- `reusable-pr.yml` - application CI and DAST.
- `reusable-license-gate.yml` - CycloneDX license-policy validation.
- `reusable-codeql.yml` - CodeQL analysis.
- `reusable-cd-dev.yml` - DEV build and deployment.
- `reusable-release.yml` - release build, STG validation, PROD promotion, rollback, and publication.
- `reusable-deploy-pro.yml` - manual PROD fallback and publication recovery.

Call workflows from an application repository with:

```yaml
jobs:
  example:
    uses: in2workspace/eudistack-devops-workflows/.github/workflows/reusable-codeql.yml@main
```

Repository-specific dispatchers, secrets, environments, license policy, and license exceptions remain in each application repository.

## Shared scripts

Reusable workflows load the scripts through
`in2workspace/eudistack-devops-workflows/.github/actions/setup-scripts@main`.
The action exports `EUDISTACK_DEVOPS_SCRIPTS` for subsequent workflow steps.

If this repository is private, enable access for consuming repositories under
**Settings > Actions > General > Access**.
