# ADR-0057: Test containers: one wrapper, three run-time boundaries, a lint that says what it is
Status: Accepted (integrator decision, 2026-11-12) · Date: 2026-11-12 · Decider: integrator · Number: 0057 · Related: GF-010, ADR-0033 (software update tests), ADR-0021 (layers)

## Context

On 2026-11-11 (16:47, 19:13, 20:28) `tests/integration/update_migrate.sh` ran `docker run --privileged` with systemd as PID 1. The
container shared the host's `/dev`: its systemd-vconsole-setup and udev ran on the host's devices, the owner's Hyprland session
received SIGHUP, SDDM hit start-limit-hit and left a black screen. Each time the owner had to power off.

## Decision

1. Every test container is run by one wrapper, `tests/integration/container.sh`. The tests no longer call docker.
2. The boundaries are at RUN TIME, and each is tested with a stub docker or in the VM:
   - the wrapper refuses anything dangerous it is handed (an option before the image, an image not pinned by `@sha256:`, an exec in a
     container it did not start, a mount source outside a short list, a changed global), always before docker is called
     (`tests/shell/container_wrapper.sh`);
   - `update_migrate.sh` fails closed outside a virtual machine: VM or CI markers, no graphical session however it is seen, and a
     refusal when it cannot tell; no override (`tests/shell/update_migrate_refusal.sh`);
   - the virtual machine, the only place that script runs (`scripts/gates/vm-drill.sh update-migrate`).
3. The static guard `tests/ci/no_privileged_containers.py` is a LINT against ACCIDENTAL reintroduction by people or agents. It is
   not a sandbox against deliberately written code, and says so in its header and in `docs/testing/README.md`. It reads every tracked
   text file except `docs/`; a product-code false positive is waived by exact file and line text in `ALLOW`.
4. The container that runs systemd has `CAP_SYS_ADMIN` minus `MKNOD`, a private cgroup namespace, a tmpfs `/run`, no device and no
   host path, and masked console units. A user namespace is a daemon setting with docker, so the VM remains the real boundary.

## Consequences

- A new test that needs a container goes through the wrapper; a new kind of mount is a change to `gf_mount`, reviewed.
- A reviewer who finds a spelling the lint misses has found a lint gap to close, not a hole in the boundary; the boundary is judged
  by the run-time tests.
