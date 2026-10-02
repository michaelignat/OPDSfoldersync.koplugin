# OPDS auto-sync for KOReader

Automatically download books from your OPDS catalogs when KOReader resumes or Wi-Fi reconnects. Optional periodic sync is also available.

Built for Android readers such as the **Bigme B6 (ARM64)**. Replaces KOReader’s stock OPDS plugin.

**[Download the latest release](https://github.com/michaelignat/OPDSfoldersync.koplugin/releases/latest)**

## Install or update from a Mac

**One script handles both.** No manual unzipping or copying files.

1. Install KOReader on your reader and open it once.
2. Download **[update-mac.command](https://github.com/michaelignat/OPDSfoldersync.koplugin/releases/latest/download/update-mac.command)**.
3. Connect and unlock your reader. Select **File transfer / MTP**.
4. Close other Android transfer apps, then run:

   ```sh
   python3 ~/Downloads/update-mac.command
   ```

5. Follow the prompt to fully exit KOReader. Keep the reader connected until finished.
6. Reopen KOReader.

The script creates missing plugin folders, installs the latest release and verifies the transfer. Existing plugin files are backed up; your credentials, settings and books stay untouched.

- **Mac requirements:** Python 3 and `libmtp`. The script can install `libmtp` through Homebrew.
- **KOReader:** current nightly with user patches enabled. The F-Droid build is unsupported.
- **Connect:** one Android device at a time.
- **Check only:** add `--check` to the command.
- **Next update:** run the same script again.

## Enable auto-sync

1. Open **OPDS catalog** and add or edit your catalog.
2. Enable **Sync catalog**.
3. Long-press the catalog → **Sync settings** → **Choose catalog sync folder**.
4. Choose a folder KOReader can write to.
5. Open the OPDS menu → **Automatic sync** and enable it.
6. Close the OPDS browser to allow automatic syncing.

## Options

| Option | Default |
| --- | --- |
| Automatic sync | Off |
| Sync on resume | On |
| Sync on network reconnect | On |
| Periodic sync | Off |
| Sync interval | 24 hours |
| Minimum time between attempts | 60 seconds |

## Licence

[AGPL-3.0](COPYING).
