# BUNNY RAMDISK BUILDER

**A12/A13 SSH ramdisk builder for macOS** — native SwiftUI app (universal: Apple Silicon + Intel).

Connect your iPhone in **DFU + usbliter8 (RP2350)**, pick an iOS version, and the tool builds a complete SSH ramdisk bootchain for you — automatically.

---

## ✅ Compatible Macs

| Requirement | Details |
|-------------|---------|
| **Chip** | Apple Silicon (M1/M2/M3/M4) **and** Intel — universal binary (arm64 + x86_64) |
| **macOS** | 13.0 (Ventura) or newer |
| **Rosetta** | Apple Silicon Macs need Rosetta for 3 bundled tools (`gtar`, `iproxy`, `sshpass`) — installed automatically by the setup script |
| **Dependencies** | Homebrew + `ipsw` CLI (blacktop/tap) + `pyimg4` — auto-installed by the app on first launch (or `setup_dependencies.sh`) |
| **Hardware** | RP2350 (Raspberry Pi Pico 2) + [usbliter8](https://github.com/prdgmshift/usbliter8) firmware + iPhone A12/A13 |

**Supported devices (A12/A13):**
- iPhone XR, XS, XS Max (A12)
- iPhone 11, 11 Pro, 11 Pro Max (A13)
- (uses usbliter8 — pwned DFU required)

---

## 📥 Installation (step by step)

### 1. Download the app
- Go to **Releases** → `BUNNY-RAMDISK-BUILDER.dmg`
- Open the DMG, drag **BUNNY RAMDISK BUILDER.app** into **Applications**

### 2. First launch
- Right-click the app → **Open** (first time only — ad-hoc signed, Gatekeeper warning is expected)
- The app **automatically**:
  1. Copies its build engine to `~/Library/Application Support/BUNNY RAMDISK BUILDER/engine`
  2. Checks dependencies (`ipsw`, `pyimg4`) — if missing, click **Install** and it sets everything up for you
  3. Detects your connected device

### 3. Manual dependency setup (optional)
If you prefer to install dependencies yourself:
```bash
curl -fsSL https://raw.githubusercontent.com/bunnyciaa/BUNNY-RAMDISK-BUILDER/main/setup_dependencies.sh -o setup_dependencies.sh
chmod +x setup_dependencies.sh
./setup_dependencies.sh
```

---

## 🚀 How to use

1. **Enter DFU + pwn:**
   - Put your iPhone in DFU mode
   - Connect the **RP2350** with usbliter8 firmware
   - Connect the iPhone to your Mac (USB-A → Lightning cable recommended)
2. **Device detected** — the app shows NAME / PRODUCT / MODEL / CPID / PWND status automatically
3. **Load Firmwares** — signed iOS versions for your device are fetched (e.g. iOS 18.7.10 for A12, 26.6.1 for A13)
4. **Pick a version** — the tool shows exactly which IPSW files it will download + estimated size
5. **Build** — fast parallel downloader (ZIP64 range chunks, ~15x faster), then builds the full bootchain:
   - Patched iBEC (usbliter8)
   - Patched kernel (AMFI + debugger)
   - SSH ramdisk (SSH injected, password `alpine`)
   - with-fw firmwares + RestoreSEP
6. **DONE popup** — bootchain + auto-created ZIP

### Output
- **Bootchain:** `~/Library/Application Support/BUNNY RAMDISK BUILDER/engine/bootchain/`
- **ZIP (for the BUNNY RAMDISK app):** `~/BUNNY RAMDISK/ramdisk/`
- **Log file:** `~/BUNNY RAMDISK/ramdisk_builder_swift.log`

---

## 🔧 Troubleshooting

| Problem | Fix |
|---------|-----|
| "device pwn state lost" | Re-enter DFU + re-pwn with usbliter8 (RP2350) |
| Download stalls | Automatic — the tool retries (up to 3x) with a fresh connection |
| Build fails with python error | Run `setup_dependencies.sh` (pyimg4 for the correct python3) |
| Screen stays blank after boot | Cosmetic — display init quirk; SSH still works |
| Gatekeeper "unidentified developer" | Right-click → **Open** |

---

## ⚠️ Important

- **Research/educational use on devices you own only.**
- The build engine (iBoot/kernel patchfinders) is based on the open-source [ICH_A12+ Ramdisk](https://github.com/Pa7r0n/ICH_A12_plus_Ramdisk) toolkit — MIT licensed, credit to @Official_I_C_H.

---

**Made by @bunnyciaa**