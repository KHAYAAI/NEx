# hub/identity

Phase 6 (`CLAUDE.md` §5): "Integrate the SE050 secure element for
device identity (replaces any software-only key storage)."

No SE050 exists in this environment — no real hardware exists for any
phase of this project (`hub/README.md`, `pocket/README.md`). What's
here instead, real and tested (`tpm-identity-demo.sh`, reran multiple
times clean): a genuine TPM 2.0 software simulator (`swtpm`, driving
the actual TPM2 command protocol via `tpm2-tools`, not a mock of an
API) generating a device-identity key, signing an assertion, and
verifying it — the same property class an SE050 provides through its
own applet interface: the private key is generated inside the security
module and never leaves it; only signing operations cross the
boundary.

## What it proves

1. A real TPM simulator starts and responds to the real protocol.
2. A signing key is generated in-module — no export command exists to
   pull the private key out, by construction, not by convention.
3. A signature over a device-identity assertion verifies correctly.
4. A tampered assertion is correctly rejected.

## What it doesn't prove

This is a software TPM, not an SE050. It doesn't validate:
tamper-resistance against physical attacks (a TPM simulator has none;
an SE050 is designed to resist them), the SE050's specific applet/API
surface, or anything about how a real hub would provision and rotate
this key across its lifecycle. Swapping `tpm2-tools` calls for an
SE050 PKCS#11/EdgeLock integration once real hardware exists is the
actual remaining work — this proves the pattern (generate in-module,
never export, sign/verify at the boundary) that integration needs to
preserve, not the hardware property itself.

## Running it

```sh
apt install swtpm tpm2-tools
./tpm-identity-demo.sh
```

No root required.
