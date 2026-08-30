# Analyse Disk Storage

A fast, single-pass disk storage analysis and reporting utility built with native .NET APIs in PowerShell. It rapidly scans directories, displays live storage metrics in the terminal, and generates a clean, interactive HTML report.

---

## Features

- **High Performance:** Uses single-pass `.NET EnumerateFiles / EnumerateDirectories` traversal for low memory overhead and fast scanning.

- **Live Terminal UI:** Displays real-time scan metrics including processed folders, files, errors, and the current path without excessive terminal output.

- **Instant Dashboard:** Shows a terminal summary with the top 5 largest folders and top 5 largest files.

- **Interactive HTML Report:**
  - Clean and modern interface.
  - KPI cards for total size, directory depth, total items, and scan runtime.
  - Top storage consumers with size percentages and navigation links.
  - Interactive folder tree with expand/collapse controls.
  - Client-side search and sorting by size or name.
  - Easy path copying with clipboard support.
  - Automatic report opening in the default browser.

---

## Quick Start

### Option 1: Run with Batch File — Recommended

Double-click `run.bat` to launch the tool in interactive mode.

### Option 2: Run from PowerShell

Right-click `script.ps1` and select **Run with PowerShell**.

### Option 3: PowerShell CLI / Automation

Run the script directly with optional parameters:

```powershell
# Interactive prompt mode
.\script.ps1

# Analyze a specific directory with a depth limit
.\script.ps1 -Path "C:\sandboxes" -MaxDepth 3

# Custom report output path and prevent automatic browser opening
.\script.ps1 -Path "D:\Projects" -MaxDepth 2 -OutHtml "D:\Reports\Storage.html" -NoOpen

# Display tool version
.\script.ps1 -Version
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
