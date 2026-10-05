# my-infra: EC2 on AWS with Terraform and GitHub Actions

Launch an EC2 instance on AWS using Terraform, deployed through a GitHub Actions CI/CD pipeline.
GitHub Actions authenticates to AWS with OIDC (short-lived tokens), so no AWS access keys are stored in GitHub.

```
GitHub (code) -> GitHub Actions -> Terraform -> AWS -> EC2 instance
```

## How the pipeline works

```
        CI (PRs and pushes)                          CD (main only)
+----------------------------------+      +-----------------------------------+
| validate  ->  plan               |  ->  | approval -> apply -> verify       |
| fmt, lint,    save plan file,    |      | human      apply the   confirm EC2 |
| security scan comment on PR      |      | gate       SAME plan   is running   |
+----------------------------------+      +-----------------------------------+
```

| Event | What runs |
|---|---|
| Pull request to `main` | `validate` then `plan` (plan is posted as a PR comment) |
| Push/merge to `main` | `validate`, `plan`, then `deploy` (waits for manual approval) |
| Manual "Run workflow" on Terraform Destroy | `destroy` (waits for manual approval) |

The `plan` job saves a plan file and the `deploy` job applies that exact file, so what you reviewed is what gets applied.

## Repository layout

```
my-infra/
├── .github/workflows/
│   ├── terraform.yml        # CI/CD pipeline
│   └── destroy.yml          # manual destroy
├── .gitignore
├── .terraform.lock.hcl      # commit this (pins provider versions)
├── main.tf                  # EC2 instance + AMI lookup
├── outputs.tf               # instance_id, private_ip
├── variables.tf             # region, instance type, name
├── versions.tf              # Terraform/provider versions + S3 backend
└── README.md
```

## Prerequisites

- AWS account with admin access (for the one-time setup only)
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.10 or newer
- [Git](https://git-scm.com/) and a GitHub account

## What a new user must change

Search the repo for every value below. Nothing else needs editing to get started.

| Where | What to change | Example |
|---|---|---|
| `versions.tf` | `bucket` must be YOUR S3 state bucket name (globally unique) | `jane-tfstate-98765` |
| `versions.tf` | `region` in the backend block, if your bucket is not in `us-east-1` | `eu-west-1` |
| `variables.tf` | `aws_region` default, if not using `us-east-1` | `eu-west-1` |
| `.github/workflows/terraform.yml` | `AWS_REGION` in `env:`, if not using `us-east-1` | `eu-west-1` |
| `.github/workflows/destroy.yml` | `aws-region`, if not using `us-east-1` | `eu-west-1` |
| `trust-policy.json` (local file, do not commit) | `<ACCOUNT_ID>`, `<ORG>`, `<REPO>` | see Step 4 |
| GitHub secret `AWS_ROLE_ARN` | Role ARN with YOUR account ID | `arn:aws:iam::123456789012:role/github-actions-terraform` |
| `variables.tf` (optional) | `instance_type`, `instance_name` | `t3.small`, `my-server` |

Keep the region consistent in all four places (backend, provider variable, and both workflows). A mismatch is the most common cause of confusing errors.

## Setup

### Step 1: Clone and enter the project

```bash
git clone https://github.com/<YOUR_GITHUB_USERNAME>/my-infra.git
cd my-infra
```

If you are starting from scratch instead:

```bash
mkdir my-infra && cd my-infra
mkdir -p .github/workflows
git init
```

### Step 2: Create the S3 bucket for Terraform state (one-time, manual)

Terraform cannot create the bucket that stores its own state, so create it by hand.

```bash
aws s3api create-bucket --bucket <YOUR_UNIQUE_BUCKET_NAME> --region us-east-1

aws s3api put-bucket-versioning \
  --bucket <YOUR_UNIQUE_BUCKET_NAME> \
  --versioning-configuration Status=Enabled
```

For any region other than `us-east-1`, add:
`--create-bucket-configuration LocationConstraint=<REGION>`

Then update `bucket` in `versions.tf` to this name.

Checkpoint: `aws s3 ls` lists your bucket.

### Step 3: Test locally first

If it does not work on your laptop, it will not work in the pipeline.

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply      # type yes
```

Confirm the instance exists in the AWS Console (EC2), then clean up:

```bash
terraform destroy    # type yes
```

Commit the lock file so CI uses the same provider versions:

```bash
git add .
git commit -m "Add Terraform EC2 config"
```

### Step 4: Let GitHub talk to AWS (OIDC, one-time)

**4a. Create the identity provider in AWS**

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

If it says the provider already exists, that is fine; skip to 4b.

**4b. Find your account ID**

```bash
aws sts get-caller-identity --query Account --output text
```

**4c. Create `trust-policy.json`** (keep it local; do not commit it)

Replace `<ACCOUNT_ID>`, `<ORG>` (your GitHub username or organization), and `<REPO>` (`my-infra`).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*"
      }
    }
  }]
}
```

The `sub` condition is the security gate: only your repo can assume this role.

**4d. Create the role and attach permissions**

```bash
aws iam create-role \
  --role-name github-actions-terraform \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam attach-role-policy --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
```

These `FullAccess` policies are for learning only. See "Hardening" below.

### Step 5: Configure GitHub

1. Create an empty repo on GitHub named `my-infra` (private, no README).
2. Connect and push `main`:

```bash
git branch -M main
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/my-infra.git
git push -u origin main
```

3. Add the secret: **Settings -> Secrets and variables -> Actions -> New repository secret**
   - Name: `AWS_ROLE_ARN`
   - Value: `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-terraform`
4. Create the approval gate: **Settings -> Environments -> New environment -> `production`** and add yourself under **Required reviewers**.
5. Protect `main`: **Settings -> Branches -> Add rule** for `main`
   - Require a pull request before merging
   - Require status checks: `Validate & Scan` and `Terraform Plan`

### Step 6: Run the pipeline

```bash
git checkout -b add-ci
git add .
git commit -m "Add CI/CD pipeline"
git push -u origin add-ci
```

1. Open a Pull Request on GitHub. `validate` and `plan` run; the plan appears as a PR comment (`1 to add`).
2. Review and merge the PR.
3. Go to the **Actions** tab, open the running workflow, and click **Approve** on the deployment.
4. The `verify` step waits until the instance is `running`. Check EC2 in the AWS Console.

### Step 7: Destroy when finished

Go to **Actions -> Terraform Destroy -> Run workflow**, then approve. Or locally:

```bash
terraform init
terraform destroy
```

## Try the change-and-react loop

1. Branch, then change `instance_type` to `t3.small` in `variables.tf`
2. Open a PR and read the plan (`~ update in-place` or `-/+ replace`)
3. Merge, approve, and watch AWS update

Also try breaking formatting on purpose (extra spaces in a `.tf` file). The pipeline should fail at `Format check` before touching AWS.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `fatal: 'origin' does not appear to be a git repository` | Remote not set. Run `git remote add origin https://github.com/<USER>/my-infra.git` |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` does not match `repo:<ORG>/<REPO>:*`, or the workflow lacks `id-token: write` |
| `Could not assume role` / secret is empty | `AWS_ROLE_ARN` secret missing or misspelled |
| `BucketAlreadyExists` | S3 bucket names are global; choose another |
| `NoSuchBucket` during `terraform init` | `bucket` in `versions.tf` does not match the one you created, or wrong region |
| `Error acquiring the state lock` | A previous run crashed. Remove the stale `.tflock` object in S3 under the state key |
| `terraform fmt -check` fails | Run `terraform fmt` locally and commit |
| `Unsupported argument: use_lockfile` | Terraform is older than 1.10. Upgrade |
| `AccessDenied` on `ssm:GetParameter` | Attach `AmazonSSMReadOnlyAccess` to the role |
| `deploy` job never starts | It is waiting for approval on the `production` environment, or you are on a PR (deploy only runs on push to `main`) |
| Plan artifact not found in `deploy` | `plan` job failed or the artifact expired (retention is 5 days). Re-run the workflow |

## Hardening (after you have it working)

1. Replace the `FullAccess` managed policies with a least-privilege custom policy.
2. Use separate roles: read-only for PR plans, write access only for `main`.
3. Set Checkov `soft_fail: false` so security findings block merges.
4. Add `dev` and `prod` environments with separate state keys.
5. Add a scheduled drift-detection workflow (`terraform plan -detailed-exitcode`).
6. Add Infracost to show monthly cost in PR comments.
7. Enable default encryption and block public access on the state bucket.

## Security notes

- Never commit `trust-policy.json`, `*.tfstate`, `tfplan`, or any AWS keys.
- Plan files can contain resolved sensitive values. Keep the repo private and artifact retention short.
- The `production` environment approval is your last line of defense. Keep a required reviewer on it.

## Cost note

A `t3.micro` is inexpensive but not free outside the free tier. Always destroy resources you are not using.
