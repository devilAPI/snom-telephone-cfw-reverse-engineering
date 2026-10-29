# snom v10 SWU firmware format (D8xx line)

The D8xx phones (D815, D815W, etc.) use [SWUpdate](https://sbabic.github.io/swupdate/)
instead of the raw `.bin` format used by D3xx/D7xx. The firmware ships as a `.swu`
file — a cpio archive.

## Layout

```
snomD815-10.1.226.16-SIP-r.swu  (cpio archive, SVR4 with CRC)
├── sw-description               metadata (libconfig format)
├── sw-description.sig           RSA-2048 SHA-256 signature over sw-description
├── u-boot.bin                   bootloader (unencrypted, flashed to mtd "uboot")
└── snomD815-rootfs2.ubifs.enc   AES-256-CBC encrypted UBIFS rootfs image
```

## Crypto

### Signature verification
- `sw-description.sig` is an RSA-2048 PKCS#1 v1.5 signature over `sw-description`.
- Verified against `/firmware1.pub` on the device (RSA-2048).
- The `swupdate` binary is invoked with `-k /firmware1.pub`.

### Rootfs encryption
- The rootfs is AES-256-CBC encrypted.
- Key and IV are stored at `/firmware1.aes` on the device, single line:
  `<64-char hex key> <32-char hex IV>`
- The `swupdate` binary is invoked with `-K /firmware1.aes`.
- The `sw-description` marks the image with `encrypted = true` and states the
  `decrypted-size`.

### Legacy key
- `/firmwareUXM.pub` is an RSA-1024 key, likely for backward compatibility with
  the old `.bin` format or UXM platform images.

## Decryption

```sh
# Extract cpio
mkdir swu-contents && cd swu-contents
cpio -id < ../snomD815-10.1.226.16-SIP-r.swu

# Read key+IV from the device (or from keys/snomD815-firmware1.aes)
read -r KEY IV < /path/to/firmware1.aes

# Decrypt rootfs
openssl enc -aes-256-cbc -d -K "$KEY" -iv "$IV" \
  -in snomD815-rootfs2.ubifs.enc -out snomD815-rootfs2.ubifs

# Extract UBIFS (requires ubi_reader: pip install ubi_reader)
ubireader_extract_files -o rootfs snomD815-rootfs2.ubifs
```

## sw-description format

The metadata is in libconfig format. Key fields:

```
software = {
    version = "10.1.226.16";
    snomD815: {
        hardware-compatibility: [ "1.0", "2.0" ];
        copy1: {
            images: (
                { name="u-boot"; filename="u-boot.bin"; type="flash"; mtdname="uboot"; },
                { name="rootfs"; filename="*.ubifs.enc"; type="ubivol"; volume="rootfs1";
                  encrypted=true; properties={decrypted-size="84566016";} }
            );
            bootenv: ( { name="rootfsvol"; value="rootfs1"; } );
        };
        copy2: { /* same but volume="rootfs2" — A/B update scheme */ };
    };
};
```

The D8xx uses an A/B rootfs scheme: `rootfs1` and `rootfs2` are UBI volumes,
and `bootenv` selects which one to boot. The update always writes to the
inactive slot.

## Differences from .bin format (D3xx/D7xx)

| | D3xx/D7xx `.bin` | D8xx `.swu` |
|---|---|---|
| Container | raw: sig + keyblock + payload | cpio (SWUpdate) |
| Signature | RSA-1024 SHA-1 over body | RSA-2048 SHA-256 over sw-description |
| Encryption | AES-128-CBC, passphrase in RSA keyblock | AES-256-CBC, key+IV in `/firmware1.aes` |
| Rootfs | tar.gz extracted over `/` | UBIFS image written to UBI volume |
| Update | destructive overwrite | A/B slot switching |
| Key on device | `/firmware1.pub` (RSA-1024) | `/firmware1.pub` (RSA-2048) + `/firmware1.aes` |
