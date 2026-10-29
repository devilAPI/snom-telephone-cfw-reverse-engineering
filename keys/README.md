# snom v10 firmware keys

Keys are **per model/line**. A D7xx key will NOT open a D3xx image.

## D3xx / D7xx (.bin format) — RSA-1024

Each public key verifies the SHA-1 signature over a `.bin` firmware image and is
used with `openssl pkeyutl -verifyrecover` to recover that image's AES-128-CBC
passphrase.

| File | Model line | Source |
|------|-----------|--------|
| `snomD3xx-firmware1.pub` | D375, D385 | Dumped from D375 at `/firmware1.pub` |
| `snomD785-firmware1.pub` | D785 | Dumped from D785 at `/firmware1.pub` |

Usage:
```sh
tools/fw-unpack.sh original_firmware/snomD375-10.1.64.17-SIP-r.bin keys/snomD3xx-firmware1.pub out_d375
```

## D8xx (.swu format) — RSA-2048 + AES-256

The D8xx line uses SWUpdate. Signature verification uses an RSA-2048 key
(`firmware1.pub`). The rootfs payload is AES-256-CBC encrypted; the key+IV are
stored on the device at `/firmware1.aes`.

| File | Model | What |
|------|-------|------|
| `snomD815-firmware1.pub` | D815W | RSA-2048 public key for signature verification |
| `snomD815-firmwareUXM.pub` | D815W | Legacy RSA-1024 key (UXM compatibility) |
| `snomD815-firmware1.aes` | D815W | AES-256 key + IV for rootfs decryption |

Usage:
```sh
tools/swu-unpack.sh original_firmware/snomD815-10.1.226.16-SIP-r.swu keys/snomD815-firmware1.aes out_d815
```
