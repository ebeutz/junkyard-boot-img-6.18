# Secrets in this repo

One thing lives here: **`junkyard-fleet.key.age`**, the fleet SSH deploy key,
encrypted with age to every public key in `recipients.txt`.

# The fleet deploy key

`rootfs/authorized_keys` holds the **public** half, which is baked into every
image (see `SSH_AUTHORIZED_KEYS` in the Makefile). The **private** half is what
lets you actually reach the fleet, and it is shared across the engineering team
— so it is distributed the same way as everything else here: encrypted to each
person's own public key, never sent as a file.

| File | Tracked? | What it is |
| --- | --- | --- |
| `junkyard-fleet.key.age` | ✅ committed | The fleet private key, encrypted to `recipients.txt`. |
| `../rootfs/authorized_keys` | ✅ committed | The matching public key, baked into every image. |
| `~/.ssh/junkyard-fleet` | ❌ never in repo | The decrypted private key on your machine, mode 0600. |

## Getting the key onto your machine

```sh
age -d -i ~/.ssh/id_ed25519 secrets/junkyard-fleet.key.age > ~/.ssh/junkyard-fleet
chmod 600 ~/.ssh/junkyard-fleet
```

Then use it explicitly — it is not your default identity:

```sh
./flash-nmap.sh -i ~/.ssh/junkyard-fleet --flash 10.0.0.0/24
SSH_OPTS='-i ~/.ssh/junkyard-fleet' ./flash-ssh.sh kalm@10.0.0.23
ssh -i ~/.ssh/junkyard-fleet kalm@10.0.0.23
```

## Adding a teammate

Add their SSH **public** key to `recipients.txt`, re-encrypt, and commit both:

```sh
age -R secrets/recipients.txt -o secrets/junkyard-fleet.key.age ~/.ssh/junkyard-fleet
```

Re-encrypting is required — age has no incremental grant, so a new recipient
cannot read the old ciphertext.

## Two properties to keep in mind

**It has no passphrase.** Fleet runs are non-interactive, so the key has to be
usable unattended. Anyone holding the decrypted file has root on every device,
which is the trade being made deliberately — the protection is that the
ciphertext is only readable by `recipients.txt`.

**Rotation costs a full sweep.** The public half is *baked into the image*, so
revoking the key is not an edit on the devices — it means building a new image
and OTA-ing every unit. Removing someone from `recipients.txt` stops them
decrypting *future* commits; it does not invalidate a copy they already
decrypted. Plan rotation as a fleet operation, and prefer adding people to
re-issuing the key.
