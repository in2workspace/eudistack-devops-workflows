# eudistack-devops-workflows

Reusable CI/CD workflows, deployment templates, and automation scripts for
EUDIStack applications.

## Workflow families

### Common

- `common-codeql-java.yml` - CodeQL analysis for Java applications.
- `common-codeql-javascript.yml` - CodeQL analysis for JavaScript and
  TypeScript applications.
- `common-license-gate.yml` - CycloneDX license-policy validation for Gradle
  and npm projects.

### ECS APIs

- `ecs-api-pr.yml` - Java API CI, container startup, and DAST.
- `ecs-api-cd-dev.yml` - DEV image build and ECS deployment.
- `ecs-api-release.yml` - release build, STG validation, exact image promotion,
  PROD deployment, rollback, and publication.
- `ecs-api-deploy-pro.yml` - manual PROD fallback and publication recovery.

### Angular/Ionic SPAs

- `spa-pr.yml` - changed-path detection, Node/npm quality checks, Jest
  coverage, SonarCloud, informational Trivy, a served development build, and
  a ZAP Ajax baseline with a blocking High/Critical gate.
- `spa-cd-dev.yml` - build and attest a DEV artifact, render runtime
  configuration, publish an immutable S3 release, activate `/wallet/`,
  invalidate every matching CloudFront distribution, verify, smoke test, and
  roll back on activation validation failure.
- `spa-release.yml` - build the production SPA once from an exact
  `release/vX.Y.Z` branch, validate it in STG, promote that same base artifact
  to protected PRO, and publish the GitHub Release only after monitoring
  succeeds.
- `spa-deploy-pro.yml` - protected manual fallback that downloads a named
  release run, verifies its evidence and artifact identity, applies release
  ordering policy, and idempotently completes production deployment and
  publication.

SPA consumers call `common-codeql-javascript.yml` and
`common-license-gate.yml` as sibling jobs next to `spa-pr.yml`, matching the
ECS API caller pattern. npm consumers disable Java setup and provide their
dependency-installation and SBOM commands.

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
- `EUDISTACK_DEVOPS_SPA_SCRIPTS`
- `EUDISTACK_DEVOPS_REPOSITORY_SCRIPTS`

The action itself must also be pinned to a full commit SHA. Each job that uses a
shared script must invoke the action because values written to `GITHUB_ENV` are
job-scoped.

## SPA workflow contract

Consumers pin reusable workflows to a full commit SHA. Each SPA job then checks
out this public repository again at `${{ job.workflow_sha }}` into
`.eudistack-devops-workflows`. Scripts therefore come from the exact reusable
workflow revision; no mutable `main` self-reference or setup-action bootstrap
is involved. `job.workflow_sha` is the supported reusable-workflow source
identity; the older proposed `github.job_workflow_sha` spelling is not a
GitHub context property.

The build defaults match `eudistack-core-wallet-pwa`: Node 22/npm,
`dist/out/browser` for production and `www` for development. Commands, output
paths, public smoke/ZAP URLs, concurrency groups, and runtime public values are
typed reusable-workflow inputs. Lint is opt-in so repositories can migrate
without converting pre-existing lint debt into a new deployment blocker. The
release version is derived only from
`release/vX.Y.Z`; `package.json` must contain the same version so package
metadata, build metadata, the CycloneDX SBOM, and the GitHub Release cannot
diverge.
`RELEASE_VERSION=X.Y.Z` is present for the production prebuild. DEV records
`<package-version>+dev.<run-number>.<short-sha>` as deployment metadata while
the application build retains its normal package version.

Runtime values are rendered from `assets/env.template.js`. Placeholders may be
`${NAME}`, `{{NAME}}`, or `__NAME__`; every name in
`runtime_required_variables` must be present and used. Non-secret public URLs
and identifiers can be passed in the appropriate `*_public_config_json` input.
The standard `LOGS_ENABLED`, `WALLET_MODE`, and `PREFERRED_GRANT` values are
read directly from each job's GitHub Environment variables and override the
corresponding JSON values when configured.
`WIA` and `WIA_INSTANCE_KEY_JWK` are protected Environment secrets. Their
values are never written to logs or evidence. Evidence records only the
SHA-256 of the rendered `assets/env.js`.

Required caller configuration:

- GitHub Environments: `dev`, protected `stg`, and protected `pro`.
- Secrets: `SONAR_TOKEN`, environment-specific AWS access key and secret key,
  `AWS_REGION`, `WIA`, and `WIA_INSTANCE_KEY_JWK`.
- Public caller inputs: smoke URLs, PR ZAP URL, and runtime public JSON.
- Resource inputs: `project_name`, `region_code`, and normally
  `spa_prefix: /wallet/`.

Configure repository rules and deployment environments with the SPA profile:

```powershell
.\scripts\repository\setup-repository-settings.ps1 `
    -Repository 'OWNER/REPOSITORY' `
    -Profile spa `
    -DryRun
```

Inspect the dry-run output and repeat without `-DryRun`. The profile selects
the SPA PR check contexts and repository-level AWS secret names. It creates
the `dev`, `stg`, and `pro` environments but cannot populate their protected
variables or secrets; configure the runtime values listed above separately.

AWS resource names are
`<project>-<environment>-s3-<region_code>-spa`; CloudFront distributions are
discovered by Comment prefix
`<project>-<environment>-cdn-<region_code>-`. All matching distributions are
invalidated for `/<spa_prefix>/*`, and every invalidation is awaited.

## SPA artifact and deployment model

The immutable base contains the compiled SPA and `env.template.js`, but not
`env.js`. A canonical manifest lists every regular file using sorted relative
paths, sizes, and SHA-256 hashes. It rejects symlinks, unsafe paths, missing
files, changed files, and unexpected files. Its aggregate digest is the
**base artifact digest**. STG and PRO materialize that base independently by
adding only the rendered `assets/env.js`; each resulting environment package
has its own package digest and separate `env.js` digest.

Environment packages are stored under
`s3://<bucket>/releases/v<version>/<package-digest>/` (DEV uses a commit/run
release key). Activation copies the exact immutable prefix to the controlled
live prefix with deletion of stale files. Static assets receive a one-year
immutable cache policy. `assets/env.js`, `ngsw.json`, and `index.html` receive
`no-store`; entry points are copied last.

Deployment state is outside the live prefix under `.eudistack-spa-state/`, so
live `sync --delete` cannot remove it. Before activation the workflow snapshots
the current deployment. If no state exists, it automatically copies the live
site into an immutable legacy snapshot and treats it as version `0.0.0`.
Activation, CloudFront waiting, exact S3 verification, or smoke/monitor failure
reactivates that exact previous prefix. State is finalized only after
validation succeeds.

Release evidence schema v1 binds repository, version, source SHA, base
manifest and archive digests, STG package and `env.js` digests, bucket,
immutable/live prefixes, CloudFront invalidations, and smoke result. The base
artifact and evidence are attested. Production validates both, requires a
strictly newer version, and publishes final state and the GitHub Release only
after successful monitoring. Manual fallback permits the same version only
with the same base digest; an older version additionally requires
`allow_downgrade: true` and a non-empty reason.

Minimum AWS IAM capabilities are scoped access to the named environment
bucket (`s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`,
with `HeadObject` covered by `s3:GetObject`) and CloudFront discovery/invalidation
(`cloudfront:ListDistributions`, `cloudfront:CreateInvalidation`,
`cloudfront:GetInvalidation`). Existing access-key authentication is retained.

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

This repository is public. Consumers still pin every reusable workflow to a
full commit SHA and the workflow checks out that same SHA for its scripts.
