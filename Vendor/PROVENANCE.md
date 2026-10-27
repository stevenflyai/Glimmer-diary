# Vendored dependencies

SQLCipher source release: `v4.19.0` from `https://api.github.com/repos/sqlcipher/sqlcipher/tarball/v4.19.0`.

Downloaded archive SHA-256:
`124037411fbe717eaf5acf061f4931c9a286f5a4112d07031e71434deb85f74a`

Generated `Sources/CSQLCipher/sqlite3.c` SHA-256:
`8640c653acadf665cce6331646f60b5b74a4690746f2c4a2d8f688a0570a0c0c`

Generated with the release's `configure` and `make sqlite3.c`. Build defines are in Package.swift, including CommonCrypto, SQLCipher extra init/shutdown, memory-only temporary storage, and thread safety. Upstream amalgamation is unmodified.

libsodium version: 1.0.22, official source from `https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz`.

Source archive SHA-256:
`adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349`

Built arm64 from source using `MACOSX_DEPLOYMENT_TARGET=14.0 CFLAGS='-O2 -mmacosx-version-min=14.0' ./configure --disable-shared --enable-static --disable-dependency-tracking` followed by `make -j4`. Headers are copied from the same source tree. No Homebrew binaries are used.

`libsodium.a` SHA-256:
`f717eed6cf51670c8d5a4c76b49077da63fd6759180edeb0ba7018d6e61ced8a`

Licenses are preserved in `Licenses/`. The application links only to Apple system libraries at runtime.
