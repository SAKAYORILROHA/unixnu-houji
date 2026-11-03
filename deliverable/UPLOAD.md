# UniXNU on Xiaomi 14 (houji / SM8650) - deliverable package

This tree is the packaged result of the UniXNU port work:

| Path | What |
| --- | --- |
| `README.md` | full engineering record: status, artifacts, reproduce steps, kernel build fixes, bring-up findings, debug channels, roadmap |
| `HANDOFF.md` | hand-off notes: what is proven, what is blocked, next steps with acceptance criteria |
| `artifacts/` | boot images (UEFI-only, embedded FAT payload, real XNU kernel, stage-gate images) and the UEFI firmware volume |
| `device/` | the houji device repository: board.toml, configs, patches, scripts, inputs |
| `patches/` | tooling patches (bootimg, IIG, toolchain, XNU work-tree diff) |
| `tools/` | host-side scripts (push/dispatch/fetch/watch, stage test, one-shot rebuild-and-boot) |

Everything here was executed with `fastboot boot` only: no partition was ever written.

The port currently boots the UEFI firmware on the phone, loads a real prelinked XNU kernel and
runs it to the end of `arm_init()`. It stops at an external abort on `0x17C10xxx` (the Qualcomm
APSS watchdog page); see README section 5 for the evidence and section 6 for the plan.
