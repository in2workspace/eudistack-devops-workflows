# eudistack-devops-workflows

Reusable CI/CD workflows, deployment templates, and automation scripts for
EUDIStack applications.

## Workflow families

### Common

- `common-codeql-java.yml` - CodeQL analysis for Java applications.
- `common-license-gate.yml` - CycloneDX license-policy validation.

### ECS APIs

- `ecs-api-pr.yml` - Java API CI, container startup, and DAST.
- `ecs-api-cd-dev.yml` - DEV image build and ECS deployment.
- `ecs-api-release.yml` - release build, STG validation, exact image promotion,
  PROD deployment, rollback, and publication.
- `ecs-api-deploy-pro.yml` - manual PROD fallback and publication recovery.

Repository-specific dispatchers, secrets, environments, license policy, and
license exceptions remain in each application repository.

Call production-capable workflows using a full commit SHA:

```yaml
jobs:
  release:
    uses: in2workspace/eudistack-devops-workflows/.github/workflows/ecs-api-release.yml@0123456789abcdef0123456789abcdef01234567
```

Do not reference `main` from application repositories. Immutable references
keep workflow reruns reproducible and prevent an unrelated shared-repository
change from altering code executed with application credentials.

## Shared scripts

The `setup-scripts` composite action exposes platform-specific script paths:

- `EUDISTACK_DEVOPS_COMMON_SCRIPTS`
- `EUDISTACK_DEVOPS_ECS_API_SCRIPTS`
- `EUDISTACK_DEVOPS_REPOSITORY_SCRIPTS`

The action itself must also be pinned to a full commit SHA. Each job that uses a
shared script must invoke the action because values written to `GITHUB_ENV` are
job-scoped.

## Adding another deployment platform

Add a separate workflow family instead of adding platform conditionals to the
ECS workflows. For an S3 and CloudFront SPA, use names such as:

- `spa-pr.yml`
- `spa-cd-dev.yml`
- `spa-release.yml`
- `spa-deploy-pro.yml`

Put reusable platform-neutral scripts in `scripts/common` and SPA deployment
scripts in `scripts/spa`. Share small composite actions for common release
policy, but keep artifact promotion, runtime verification, and rollback inside
the platform workflow family.

For SPAs, releases should promote one immutable build artifact, store a file
hash manifest, publish assets under an immutable release prefix, switch only
the mutable entry points, and retain the previous release manifest for
rollback.

## Repository access

If this repository is private, enable access for consuming repositories under
**Settings > Actions > General > Access**.
