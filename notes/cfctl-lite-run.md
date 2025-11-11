# cfctl-lite quick run

- Build and run straight from the repo:

  ```bash
  cargo run -p cfctl -- run \
    --boot /var/lib/cuttlefish/images/boot.img \
    --init /var/lib/cuttlefish/images/init_boot.img \
    --verify-boot \
    --logs-dir ./logs/run-$(date +%Y%m%d-%H%M%S)
  ```

- Defaults:
  - uses the stock cuttlefish images from `/var/lib/cuttlefish/images`.
  - writes all artifacts under `./logs/run-YYYYmmdd-HHMMSS` unless you pass `--logs-dir`.
  - creates temporary instance/assembly dirs under `/tmp/cfctl-run-*` and deletes them unless `--keep-state`.

- Outputs:
  - `cfctl-run.log` (launch_cvd stdout/stderr)
  - `console.log` (copied console snapshot)
  - `logcat.txt` (ADB logcat dump when ADB becomes ready)
  - optional kept instance dir path reported in the JSON summary when using `--keep-state`.
