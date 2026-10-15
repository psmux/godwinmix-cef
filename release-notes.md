Minimal distributions of CEF @CEF_VERSION@ built with `is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome`, so they play H.264 and AAC. Each archive is named and laid out like the official one at cef-builds.spotifycdn.com, and has `.sha1` and `.sha256` files beside it.

To build against them with the `cef` crate:

```sh
CEF_DOWNLOAD_URL=https://github.com/@REPO@/releases/download/@TAG@ cargo build --release
```

`index.json` in this release lists the platforms present, in the format of the official index. The README says how these were built, how to build them again, and the patent licensing caveat for H.264 and AAC.
