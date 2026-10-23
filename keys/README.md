# snom v10 firmware signing keys (RSA-1024, SHA-1)

Each key verifies the SHA-1 signature over a firmware image and is used with
`openssl pkeyutl -verifyrecover` to recover that image's AES-128-CBC passphrase.

Keys are **per model/line**. Confirmed empirically:
- `snomD785-firmware1.pub` (D7xx) does NOT verify D375/D385 images.

To decrypt the D375/D385 `.bin` files here you still need the **D3xx**
`firmware1.pub`, which lives at `/firmware1.pub` on a D375/D385 device.

Usage once you have the right key:
    tools/fw-unpack.sh orig_firm/snomD385-10.1.226.16-SIP-r.bin keys/snomD3xx-firmware1.pub out_d385
