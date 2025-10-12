# GitHub Repository Setup for Self-Hosted CI

This document describes the GitHub repository settings needed for the self-hosted Hetzner CI runner.

## 1. Add GitHub Runner to Hetzner Configuration

Add this to your `~/configs/hetzner/github-runner-factory.nix` in the `services.github-runners` section:

```nix
boom-runner = mkRunner { name = "boom-runner"; repo = "boom"; usePatFile = true; };
```

Then rebuild your Hetzner server:
```bash
sudo nixos-rebuild switch
```

## 2. Configure GitHub Repository Settings

### Required: Enable Manual Approval for External Contributors

This prevents random people from running malicious code on your Hetzner box.

Go to: **Settings → Actions → General → Fork pull request workflows from outside collaborators**

Set to: **"Require approval for first-time contributors"**

This means:
- Your own pushes/PRs run automatically
- First-time external contributors require manual approval
- After you approve once, their future PRs run automatically

### Alternative (More Restrictive): Require Approval for All Outside Collaborators

Set to: **"Require approval for all outside collaborators"**

This requires approval for EVERY PR from non-collaborators (not just first-time).

## 3. How to Approve CI Runs

When an external contributor opens a PR, you'll see a yellow banner that says:
**"Workflow is awaiting approval"**

Click **"Approve and run"** to allow the CI to execute.

## 4. Runner Labels

The workflow uses these labels to target your Hetzner runner:
- `self-hosted`
- `nixos`
- `hetzner`

These match the `extraLabels` in your `github-runner-factory.nix`.

## 5. Security Notes

- The workflow uses `pull_request_target` which runs in the context of the base branch, providing access to secrets
- We explicitly checkout the PR head SHA to test the actual PR code
- Manual approval prevents arbitrary code execution from untrusted sources
- The runner runs as the `justin` user with the permissions defined in your NixOS config
