# 🚀 Seedbox Media Automation: Subtitle Cleaner & Optimizer

## Project: MKV-Automation-Scripts
**Status:** Public Alpha (Configuration Version 6.0)

This repository contains a set of self-correcting Bash scripts designed to solve the common issue of high CPU usage and lag (transcoding) on seedboxes and media servers (Plex, Jellyfin). The scripts automatically remove high-overhead, image-based subtitle tracks (PGS/SSA/ASS) and replace them with efficient, compatible SRT files, guaranteeing **Direct Play** for optimal streaming performance.

---

## 💡 How It Works (The Process Model)

The solution runs in two distinct, self-correcting phases:

1.  **Conversion:** Extracts complex subtitles from the MKV container and converts them into separate `.srt` files.
2.  **Optimization:** Remuxes the original MKV, deletes the complex tracks, adds the new `.srt` track, and sets the desired default flags.

## 💾 Requirements & Dependencies

These scripts are designed to run in a Linux environment (like Ubuntu MATE) and require the following command-line tools:

| Dependency | Purpose | Installation Command (Ubuntu/Debian) |
| :--- | :--- | :--- |
| **mkvtoolnix-cli** | Muxing, demuxing, and stream property editing. | `sudo apt install mmkvtoolnix` |
| **ffmpeg / ffprobe** | Video/audio stream analysis and subtitle extraction/conversion. | `sudo apt install ffmpeg` |
| **jq** | JSON stream parser for accurate track identification from `mkvinfo` and `ffprobe`. | `sudo apt install jq` |
| **Bash** | Standard shell environment. | (Usually pre-installed) |

---

## 🛠️ Setup and Execution

### 1. Preparation

Download all three `.sh` files (`convert_ass_to_srt.sh`, `optimize_subs.sh`, `recon_files.sh`) into a single directory (e.g., `~/mkv_tools/`).

### 2. Set Permissions

Make the scripts executable:

```bash
chmod +x ~/mkv_tools/*.sh
