#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from urllib.request import Request, urlopen
from zipfile import ZipFile

RELEASE_API = "https://api.github.com/repos/michaelignat/OPDSfoldersync.koplugin/releases/latest"
DEVICE_ROOT = "/koreader"
PATCH_PATH = "patches/2-opds-autosync.lua"
COMMAND_TIMEOUT_SECONDS = 120
DOWNLOAD_TIMEOUT_SECONDS = 60
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600
BACKUP_DIRECTORY = Path.home() / "Library/Application Support/OPDS Auto Sync/backups"


def main():
    parser = argparse.ArgumentParser(description="Install or update the OPDS auto-sync plugin over USB on macOS")
    parser.add_argument("--check", action="store_true", help="compare with the latest release without changing the device")
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("Run this updater on macOS")
    os.umask(0o077)
    mtp = get_transfer_tool()
    with tempfile.TemporaryDirectory(prefix="opds-update-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        version, payload = download_release(temporary_path)
        print(f"Latest release: {version}", flush=True)
        folders = get_device_folders(mtp)
        if DEVICE_ROOT not in folders:
            raise RuntimeError("Install and open KOReader once to create the koreader folder, then try again")
        existing = get_existing_files(mtp, folders, payload)
        current_directory = temporary_path / "current"
        current_directory.mkdir()
        retrieve_files(mtp, existing, current_directory)
        changed = [name for name in payload if name not in existing or
                   (current_directory / name).read_bytes() != payload[name].read_bytes()]
        if not changed:
            print("Already up to date. No files changed.")
            return
        print(f"{len(changed)} plugin files need installing or updating.")
        if arguments.check:
            print("Check complete. No files changed on the device.")
            return
        answer = input("Fully exit KOReader on the reader. Is KOReader closed? [y/N] ").strip().lower()
        if answer not in {"y", "yes"}:
            print("Cancelled. No files changed.")
            return
        backup_directory = create_backup(current_directory, existing, version)
        print(f"Plugin backup: {backup_directory}", flush=True)
        ensure_installation_folders(mtp, folders)
        try:
            install_files(mtp, {name: payload[name] for name in changed}, existing)
            verify_directory = temporary_path / "verify"
            verify_directory.mkdir()
            retrieve_files(mtp, changed, verify_directory)
            for name in changed:
                if (verify_directory / name).read_bytes() != payload[name].read_bytes():
                    raise RuntimeError(f"Verification failed: {name}")
        except (Exception, KeyboardInterrupt):
            print("Installation interrupted. Attempting to restore the previous files…", flush=True)
            try:
                restore_files(mtp, changed, existing, backup_directory)
                print("Previous files restored; newly installed files removed.")
            except (Exception, KeyboardInterrupt):
                print(f"Automatic restore could not finish. Keep KOReader closed and restore plugin files from {backup_directory}")
            raise
        print(f"Installed {version} and verified every updated file.")
        print("Credentials, settings, progress sync and books were not read or modified. You can reopen KOReader.")


def get_transfer_tool():
    search_paths = [Path("/opt/homebrew/bin"), Path("/usr/local/bin")]
    executable = shutil.which("mtp-connect")
    for directory in search_paths:
        if executable:
            break
        candidate = directory / "mtp-connect"
        if candidate.is_file():
            executable = str(candidate)
    if executable:
        return Path(executable)
    brew = shutil.which("brew")
    for directory in search_paths:
        if brew:
            break
        candidate = directory / "brew"
        if candidate.is_file():
            brew = str(candidate)
    if not brew:
        raise RuntimeError("Homebrew and libmtp are required. Install Homebrew, run 'brew install libmtp', then try again")
    if input("Install the USB file-transfer utility (brew install libmtp)? [y/N] ").strip().lower() not in {"y", "yes"}:
        raise RuntimeError("libmtp is required to access the reader")
    subprocess.run([brew, "install", "libmtp"], check=True)
    prefix = subprocess.check_output([brew, "--prefix", "libmtp"], text=True).strip()
    return Path(prefix) / "bin/mtp-connect"


def download_release(directory):
    request = Request(RELEASE_API, headers={"Accept": "application/vnd.github+json", "User-Agent": "opds-mac-updater"})
    with urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
        release = json.load(response)
    assets = [asset for asset in release.get("assets", []) if re.fullmatch(r"opds-autosync-v[\d.]+\.zip", asset["name"])]
    if len(assets) != 1:
        raise RuntimeError("The latest release does not contain one recognised plugin ZIP")
    asset = assets[0]
    archive_path = directory / "release.zip"
    with urlopen(asset["browser_download_url"], timeout=DOWNLOAD_TIMEOUT_SECONDS) as response:
        with archive_path.open("wb") as archive_file:
            shutil.copyfileobj(response, archive_file)
    if (asset.get("digest") or "").startswith("sha256:"):
        if hashlib.sha256(archive_path.read_bytes()).hexdigest() != asset["digest"].split(":", 1)[1]:
            raise RuntimeError("Release download checksum mismatch")
    payload = {}
    with ZipFile(archive_path) as archive:
        for name in archive.namelist():
            if not re.fullmatch(r"opds\.koplugin/[A-Za-z0-9_-]+\.lua", name) and name != PATCH_PATH:
                continue
            if name in payload:
                raise RuntimeError("Duplicate plugin file in release")
            destination = directory / "release" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(name))
            payload[name] = destination
    if "opds.koplugin/main.lua" not in payload or PATCH_PATH not in payload:
        raise RuntimeError("Release is missing the plugin or Android startup patch")
    return release["tag_name"], payload


def run_mtp(mtp, arguments):
    result = subprocess.run([str(mtp), *arguments], capture_output=True, text=True, timeout=COMMAND_TIMEOUT_SECONDS)
    output = result.stdout + result.stderr
    if result.returncode or re.search(r"Error sending file|No devices|Unable to open|Could not open|LIBMTP PANIC|PTP.*error", output, re.I):
        raise RuntimeError("USB transfer failed. Keep the reader unlocked in File transfer/MTP mode, and close other transfer apps")
    return output


def get_device_folders(mtp):
    output = run_mtp(mtp.with_name("mtp-folders"), [])
    if len(re.findall(r"^Device \d+ ", output, re.M)) != 1:
        raise RuntimeError("Connect exactly one Android reader, unlock it and select File transfer/MTP")
    folders = {}
    parents = []
    for line in output.splitlines():
        match = re.match(r"^(\d+)\t( *)(.+)$", line)
        if not match:
            continue
        depth = len(match[2]) // 2
        parents = parents[:depth]
        parents.append(match[3])
        folder_path = "/" + "/".join(parents)
        if folder_path in folders:
            raise RuntimeError("Duplicate storage paths found. Disconnect additional storage before installing")
        folders[folder_path] = int(match[1])
    return folders


def get_existing_files(mtp, folders, payload):
    output = run_mtp(mtp.with_name("mtp-files"), [])
    existing = []
    for block in output.split("File ID:")[1:]:
        filename = re.search(r"^\s*Filename: (.+)$", block, re.M)
        parent = re.search(r"^\s*Parent ID: (\d+)$", block, re.M)
        if not filename or not parent:
            continue
        for name in payload:
            remote = get_remote_path(name)
            if filename[1] == PurePosixPath(remote).name and int(parent[1]) == folders.get(str(PurePosixPath(remote).parent)):
                existing.append(name)
    if len(existing) != len(set(existing)):
        raise RuntimeError("Duplicate plugin files found on the device; resolve them before updating")
    return existing


def get_remote_path(name):
    if name == PATCH_PATH:
        return f"{DEVICE_ROOT}/{name}"
    return f"{DEVICE_ROOT}/plugins/{name}"


def retrieve_files(mtp, names, destination_directory):
    if not names:
        return
    arguments = []
    for name in names:
        destination = destination_directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        arguments.extend(["--getfile", get_transfer_argument(get_remote_path(name), destination)])
    run_mtp(mtp, arguments)
    for name in names:
        if not (destination_directory / name).is_file():
            raise RuntimeError(f"Could not read plugin file: {name}")


def get_transfer_argument(source, destination):
    if "," in str(source) or "," in str(destination):
        raise RuntimeError("libmtp cannot use a file path containing a comma")
    return f"{source},{destination}"


def create_backup(current_directory, existing, version):
    BACKUP_DIRECTORY.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    backup_directory = Path(tempfile.mkdtemp(prefix=datetime.now().strftime("%Y%m%d-%H%M%S-"), dir=BACKUP_DIRECTORY))
    for name in existing:
        destination = backup_directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(current_directory / name, destination)
        destination.chmod(PRIVATE_FILE_MODE)
    (backup_directory / "update.json").write_text(json.dumps({"target_release": version, "backed_up_files": existing}, indent=2))
    return backup_directory


def ensure_installation_folders(mtp, folders):
    for folder_path in [f"{DEVICE_ROOT}/plugins", f"{DEVICE_ROOT}/plugins/opds.koplugin", f"{DEVICE_ROOT}/patches"]:
        if folder_path in folders:
            continue
        run_mtp(mtp, ["--newfolder", folder_path])
        folders = get_device_folders(mtp)
        if folder_path not in folders:
            raise RuntimeError(f"Could not create {folder_path}. No plugin files have been changed")


def install_files(mtp, payload, existing):
    arguments = []
    for name, source in payload.items():
        remote = get_remote_path(name)
        if name in existing:
            arguments.extend(["--delete", remote])
        arguments.extend(["--sendfile", get_transfer_argument(source, PurePosixPath(remote).parent)])
    output = run_mtp(mtp, arguments)
    if output.count("New file ID:") != len(payload):
        raise RuntimeError("Not all plugin files were transferred")


def restore_files(mtp, changed, existing, backup_directory):
    for name in changed:
        run_mtp(mtp, ["--delete", get_remote_path(name)])
    previous = {name: backup_directory / name for name in changed if name in existing}
    if not previous:
        return
    install_files(mtp, previous, [])
    with tempfile.TemporaryDirectory(prefix="opds-restore-verify-") as directory:
        retrieve_files(mtp, previous, Path(directory))
        for name, source in previous.items():
            if (Path(directory) / name).read_bytes() != source.read_bytes():
                raise RuntimeError("Restored plugin could not be verified")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f"Stopped: {error}", file=sys.stderr)
        sys.exit(1)
