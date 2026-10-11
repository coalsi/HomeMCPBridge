# What was left out of these documents, and why

`../DEVICE-FACTS.md` and the files in this folder were assembled on 2026-10-11 from local records. Some of those
records contain private values. They were **not** copied here. Where a document needs to mention one, it says
"[redacted]".

Left out, by kind (no values given):

- The head unit's serial number (it appears in README.md, CLAUDE.md and transcripts).
- All IP addresses and mDNS host names of the owner's devices (head unit, cluster, Macs), and adb pairing/connect
  ports seen in old notes.
- The suffix of the vendor Bluetooth pairing name (shown here as `GT7-BT-[redacted]`).
- The CarPlay dongle's UUID and MAC addresses.
- The cluster's Wi-Fi access-point name and password.
- The debug keystore fingerprint.
- A GPS position that appeared in one dump.
- A GT6-prefixed string in `ec.txt` that looks like a password or menu code.
- Any access code for the vendor's factory settings menu. The documents refer to it only as "the factory settings
  menu".
- The numeric value of `Sys_UINumber` (a UI style id). It is not known to be an access code, but it is a 5-digit
  vendor number set on factory-configuration paths, so the checker withheld it as a precaution (2026-10-11).

Kept, because they are configuration or version values rather than secrets: build fingerprint, firmware and app
version strings, panel and chip names, car-type and logo-type numbers, `mCustomerType`, app uid 10127, USB
vendor/product ids, the dongle's model and hardware-version strings and manufacture date, file hashes, and the
vendor console's "8836" / "OS 6806" firmware readouts (video-chip mode labels).

If any document in this folder is shared outside the household, re-read it first: it describes the truck's
equipment in detail.
