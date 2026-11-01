#!/usr/bin/env bash
# Cross-build OpenSSL 1.1.1w and OpenSSH for the D375. Needs docker.
# Output: tools/out/ssh/. See docs/ssh-update.md.
#
# Dynamic, against the phone's glibc 2.19, so image size stays flat. Debian
# stretch (glibc 2.24) is the newest toolchain whose output still runs there;
# the script fails if a binary needs a newer glibc symbol. OpenSSL stays on 1.1.1
# because lcsD375 links libssl.so.1.1; 1.1.1w is a drop-in for the stock 1.1.1g.
#
# Sources are fetched on the host, where TLS verification works; stretch's CA
# store is too old to be useful.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out/ssh"; SRC="$HERE/out/ssh-src"; mkdir -p "$OUT" "$SRC"
OPENSSL=1.1.1w OPENSSH=10.2p1 ZLIB=1.3.1
OPENSSL_SHA256=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8

get() { [ -f "$SRC/$(basename "$1")" ] || curl -fsSL -o "$SRC/$(basename "$1")" "$1"; }
get "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL//./_}/openssl-$OPENSSL.tar.gz"
get "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$OPENSSH.tar.gz"
get "https://zlib.net/fossils/zlib-$ZLIB.tar.gz"
echo "$OPENSSL_SHA256  $SRC/openssl-$OPENSSL.tar.gz" | sha256sum -c -

docker run --rm -e OPENSSL=$OPENSSL -e OPENSSH=$OPENSSH -e ZLIB=$ZLIB \
    -v "$SRC":/dl:ro -v "$OUT":/out debian/eol:stretch bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gcc-arm-linux-gnueabi make perl file binutils >/dev/null 2>&1
HOST=arm-linux-gnueabi P=/opt/arm
export CC=$HOST-gcc AR=$HOST-ar RANLIB=$HOST-ranlib STRIP=$HOST-strip
export CFLAGS="-Os -march=armv5te -marm -fPIC"
mkdir -p /src $P; cd /src
for f in /dl/*.tar.gz; do tar xf $f; done

cd zlib-$ZLIB; ./configure --prefix=$P --static >/dev/null; make -j$(nproc) install >/dev/null 2>&1

cd ../openssl-$OPENSSL
env -u CC -u AR -u RANLIB CROSS_COMPILE=$HOST- ./Configure linux-armv4 -march=armv5te -marm \
    shared no-tests no-unit-test --prefix=/usr --openssldir=/usr/lib/ssl --libdir=lib >/dev/null
env -u CC -u AR -u RANLIB CROSS_COMPILE=$HOST- make -j$(nproc) >/dev/null 2>&1
env -u CC -u AR -u RANLIB make DESTDIR=$P/ssl install_sw >/dev/null 2>&1

cd ../openssh-$OPENSSH
./configure --host=$HOST --prefix=/usr --sysconfdir=/etc/ssh \
    --libexecdir=/usr/libexec --with-privsep-path=/var/empty --with-pid-dir=/var/run \
    --with-ssl-dir=$P/ssl/usr --with-zlib=$P --with-sandbox=no --without-pam \
    --without-pie --disable-strip \
    LDFLAGS="-L$P/ssl/usr/lib -L$P/lib" CPPFLAGS="-I$P/ssl/usr/include -I$P/include" >/dev/null
make -j$(nproc) >/dev/null 2>&1

mkdir -p /out/lib /out/bin
cp -L $P/ssl/usr/lib/libssl.so.1.1 $P/ssl/usr/lib/libcrypto.so.1.1 /out/lib/
cp $P/ssl/usr/bin/openssl /out/bin/
for f in ssh sshd sshd-session sshd-auth ssh-keygen ssh-add ssh-agent ssh-keyscan scp sftp sftp-server ssh-keysign; do
    [ -f $f ] && cp $f /out/bin/
done
$STRIP /out/bin/* /out/lib/*
cd /out
for f in bin/* lib/*; do
    v=$($HOST-readelf -V $f | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1)
    echo "$f $(stat -c%s $f) $v"
done > /out/versions.txt
if grep -E "GLIBC_2\.(2[0-9]|[3-9][0-9])" /out/versions.txt; then echo "needs newer glibc than the phone"; exit 1; fi
chown -R '"$(id -u):$(id -g)"' /out
'
cat "$OUT/versions.txt"
