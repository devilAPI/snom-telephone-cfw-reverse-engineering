# Signing keys and the trust chain

## Which key the phone trusts

The phone verifies an update with the `/firmware1.pub` **of the firmware it
is currently running**. Flashing an image swaps the whole rootfs, including
`/firmware1.pub`. So:

> The key inside an image decides which key the **next** update must be signed with.

`tools/fw/build-custom-firmware.sh` always writes `keys/custom-d375/firmware.pub` into
`rootfs/d375/firmware1.pub` (step 1b), so every image you build accepts
follow-up images signed with the same key.

| Key | Where | Purpose |
|---|---|---|
| snom D3xx public key | `keys/stock/snomD375-firmware1.pub`, `/firmware1.pub` on stock phones | Decrypt stock D375/D385 images; put back to accept stock updates again |
| snom D7xx public key | `keys/stock/snomD785-firmware1.pub` | D7xx images only. Does **not** open D3xx images |
| snom private key | snom only | Never available. Stock images can't be re-signed |
| custom private key | `keys/custom-d375/firmware.priv.pem` (tracked: the keys are public on purpose) | Signs our images |
| custom public key | `keys/custom-d375/firmware.pub`, `/firmware1.pub` on custom phones | Verifies our images |

## The private key is the only thing that can't be recovered

The phone only stores the public key. If `keys/custom-d375/firmware.priv.pem` is
lost, as happened once already, **nobody can sign images for that phone
anymore**. Root SSH still lets you replace `/firmware1.pub` by hand, which is
the fix described below. Without SSH you would need hardware access
(serial/JTAG) or snom's recovery.

Back the private key up somewhere outside this repo (password manager, encrypted
USB stick). This repo tracks it in `keys/custom-d375/`, so it is public: anyone can
sign images that a phone running this CFW will accept.

## Rekeying a phone (new key, or lost key)

You need root SSH on the phone.

```sh
rm -rf keys/custom-d375                       # only if the old key is gone/unwanted
./tools/fw/build-custom-firmware.sh        # generates a new 1024-bit key + image
```

Then install the new public key on the running phone. The rootfs is mounted
read-only, so remount it first:

```sh
ssh root@<phone-ip> 'cat > /tmp/firmware1.pub.new' < keys/custom-d375/firmware.pub
ssh root@<phone-ip>
  mount -o remount,rw /
  cp /tmp/firmware1.pub.new /firmware1.pub
  NEWHASH=$(md5sum /firmware1.pub | cut -d' ' -f1)
  awk -v h="$NEWHASH" '{ if ($2=="firmware1.pub") print h"  firmware1.pub"; else print }' \
      /etc/checksum.md5 > /tmp/checksum.md5.new
  cp /tmp/checksum.md5.new /etc/checksum.md5
  sync
  mount -o remount,ro /
```

Check before flashing:

```sh
ssh root@<phone-ip> cat /firmware1.pub | cmp - keys/custom-d375/firmware.pub && echo OK
```

## Going back to stock firmware

Stock images are signed by snom, so the phone has to trust snom's key again.
Put `keys/stock/snomD375-firmware1.pub` back as `/firmware1.pub` (same steps as
above), then flash a stock image. Stock images contain snom's key as
`/firmware1.pub`, so after that the phone is back on the normal update path. Once you're on stock, root SSH is gone until
you redo [root-access.md](root-access.md).
