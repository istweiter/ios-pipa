# Handoff: iOS/iPadOS on Xiaomi Pad 6 (Pipa)

## Move to another Codex account

- The working tree is local at `/home/fx-mod/ios-pipa` in WSL Ubuntu 26.04. On this same Windows profile, sign into the other Codex account and open that existing folder; this keeps local files and build artifacts.
- GitHub fork: `istweiter/ios-pipa`, branch `main`. The README edit was already pushed remotely as `c1a98cd` while this handoff was being prepared. This handoff and the latest hardware note are included in the follow-up commit; inspect `git log` for its hash.
- At handoff, `NOTES.md` and `README.md` have local modifications; `README.md` includes the user's edits. Preserve both. `CODEX_HANDOFF_2026-11-20.md` is a new local handoff file. Generated kernels, roots, IPSW inputs, and firmware are local/ignored and are not guaranteed to exist after a fresh clone.
- OpenAI does not provide a full merge/move of account chat histories. An eligible account can export its data from Settings → Data controls → Export data. If the export contains the relevant Codex conversation, upload its JSON to a new chat as reference; it will not restore the original thread or sidebar. Official instructions: https://help.openai.com/en/articles/9106926-transfer-exported-conversations-between-chatgpt-accounts and https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data.

## Project and device

- Target: Xiaomi Pad 6, codename Pipa, Snapdragon 870 / SM8250-AC, Adreno 650, CSOT panel, Novatek NT36532 touch.
- Repo: `/home/fx-mod/ios-pipa`; GitHub fork above. XNU source is not available as a complete local checkout; kernels come from GitHub Actions artifacts.
- Do not overwrite stock boot/recovery/modem/persist. The intended root boot argument is `rd=ufsroot0`; do not switch it to `rd=md0`. Use temporary `fastboot boot` images while diagnosing.
- Do not replace installed launchd or alter the root without explicit user direction.

## Latest iPadOS experiment

- Built an alternate 16 GiB HFS+ root from the iPad Pro 12.9-inch 1st-generation Wi-Fi IPSW (`iPad6,7`, iPadOS 16.7.16, build `20H392`). Raw image: `/home/fx-mod/ios-pipa/research/ipados-root/ipados16-root.img`; sparse copy: `C:\Temp\ipados16-root.simg`.
- The user previously reported a Windows `fastboot flash userdata ipados16-root.img` attempt failed with `std::bad_alloc`. It is unknown whether the later sparse image was successfully written. First establish which root is currently on `userdata`; do not assume the alternate root is installed.
- The first shim paired that root with iPhone X identity (`D22AP` / `iPhone10,3`, `/product` `iPhone X` / `phone`). A temporary corrected shim was then built using the genuine iPad device tree identity (`J98aAP` / `iPad6,7`, `/product` `iPad Pro` / `pad`). It preserves the existing kernel, Pipa nodes, diagnostics, Sileo entries, and `rd=ufsroot0`.
- Corrected temporary image: `C:\Temp\shim-boot-pipa-ipados-identity-20261120.img`; SHA-256 `e6aafd41163d2d5acf870f45d9960f3e005a09fc203edd450bab2be4260d1c02`.
- Latest hardware report from the user: the UI did not visibly change; Wi-Fi appeared. Settings still does not open. The exact shim and root used in that attempt have not been independently verified. The ADT identity mismatch was real, but do not claim the iPad UI fix is complete.
- `Preferences.app` exists in the alternate root. The reason it fails to open is not known; no fresh Settings crash report has been examined. Next, verify which boot image and root were actually used, inspect a fresh boot log for model/product identity and root selection, then diagnose the Settings crash separately.
- `ProductName` in this iPadOS build's `SystemVersion.plist` may read `iPhone OS`; the IPSW/build identity is the better evidence for the root source.

## Other known state

- Touch coordinate mapping was confirmed working by the user on the prior root/boot chain.
- Wi-Fi was reported working before; it has now appeared in the latest iPadOS attempt as well. Bluetooth/audio and Metal/CoreAnimation remain separate bring-up issues; Metal kernel checks and a standalone render/readback probe passed earlier, but the system compositor was not proven to use Metal.
- Sileo appeared once after the install sequence, but package/source details are separate from the current iPadOS UI issue.

## First actions for the next Codex

1. Read this file and `NOTES.md`, then inspect `git status` before editing. Preserve the user's `README.md` edits.
2. Ask/verify whether `C:\Temp\ipados16-root.simg` was successfully flashed to `userdata`; if uncertain, use a safe read-only check rather than writing partitions.
3. Have the user boot the corrected shim only with `fastboot boot "C:\Temp\shim-boot-pipa-ipados-identity-20261120.img"` after confirming the intended root is already on userdata. This command boots temporarily; it is not a flash.
4. If UI remains phone-style, use fresh boot evidence to determine the actual `hw.model`, `hw.machine`, `/product` values, MobileGestalt cache state, and root mounted. If Settings still fails, inspect its crash report before changing files.
