# oracle-vm-grabber

Oracle Cloud's Always Free Ampere VMs are often "out of host capacity". This repository's GitHub Action retries the
launch every hour (about 54 minutes of attempts per run) until Oracle has room, then opens an issue and disables itself.

- `grab.sh`: one retry window. It reuses an existing public subnet, picks the newest Ubuntu 24.04 aarch64 image and launches
  `VM.Standard.A1.Flex` (1 OCPU, 6 GB) named `cti-verify`. It exits early if that VM already exists.
- `.github/workflows/grab.yml`: hourly schedule; credentials come from encrypted secrets
  (`OCI_USER`, `OCI_FINGERPRINT`, `OCI_TENANCY`, `OCI_REGION`, `OCI_KEY_PEM`, `SSH_PUBLIC_KEY`).

No credentials, OCIDs or IP addresses are stored in this repository or printed in the logs.
