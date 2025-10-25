Our goal is to create an Android distro that runs on Pixel hardware without any JVM stack. `drm_rect` is a demo of a compositor that can paint screen blue. Now we're trying to write a PID 1 init that can boot on a cuttlefish instance and run `drm_rect` without defering to the normal android init (called `init.stock` in our code IIRC).

NO MOCKS. NO FAKE CODE.

You are in charge of QA! Don't ask me to QA for you!

Don't create or edit markdown files unless I ask you to.

Take small small steps and test

~/configs/hetzner is the VPS where our cuttlefish instances live. We use ~/configs/hetzner/cfctl to operate these cuttlefish instances. `ssh hetzner` to get on the machine. Android Open Source Project (`aosp`) source code is checkout out in homedir -- don't hesitate to search this when you have questions about how Android works.

## Rebuilding Cuttlefish Host Tools (Hetzner)

1. `nix develop /Users/justin/configs#aosp` (or run `/nix/store/.../bin/aosp-build`) to
   enter the FHS shell on Hetzner.
2. `cd ~/aosp && source build/envsetup.sh && lunch aosp_cf_x86_64_only_phone-userdebug`
3. `m run_cvd kernel_log_monitor -j8`
4. `bash /tmp/rebuild-patched.sh` – produces `/var/lib/aosp/artifacts/cvd-host_package-
complete.tar.gz`
5. `nix-store --add-fixed sha256 /var/lib/aosp/artifacts/cvd-host_package-complete.tar.gz`
6. `just hetzner` to redeploy (configuration already consumes the tarball via
   `builtins.path`)

Always boot a test instance (`cfctl instance create-start --purpose ci --verify-boot`)
after redeploying to confirm the patched binaries behave as expected.

Feel free to tweak the wording, but that captures the workflow the new Nix plumbing
enables.
