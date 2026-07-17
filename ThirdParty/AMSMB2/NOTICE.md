# AMSMB2 (vendored)

Source: https://github.com/amosavian/AMSMB2  
Tag / commit base: **4.0.3** (`1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`)  
Bundled C core: https://github.com/sahlberg/libsmb2 @ `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03` (AMSMB2 4.0.3 submodule pin)

## Why vendored?

Upstream `Package.swift` declares:

```swift
.library(name: "AMSMB2", type: .dynamic, targets: ["AMSMB2"])
```

A dynamic SPM product becomes `AMSMB2.framework` with `@rpath`.  
When CI builds with `CODE_SIGNING_ALLOWED=NO` for 牛蛙/超级签名 re-sign, that framework is often **missing** from the IPA → install fails or app dies at launch (`dyld: Library not loaded: @rpath/AMSMB2.framework/AMSMB2`).

This copy forces **`type: .static`** so SMB code links into the main binary (same model as Citadel/SFTP).

## License

See upstream repository (AMSMB2 / libsmb2 licenses).  
No functional API changes; only product linkage type.
