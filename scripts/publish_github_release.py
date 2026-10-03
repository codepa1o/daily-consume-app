"""Publish APK + manifest as a GitHub Release. No credentials are embedded in the app."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

import publish_release as apk_tools

DEFAULT_REPO = "codepa1o/daily-consume-app"
PUBLIC_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"}


class GithubError(RuntimeError):
    def __init__(self, status, message):
        self.status = status
        super().__init__(f"GitHub HTTP {status}: {message}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class PublicRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_public_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in PUBLIC_HOSTS or parsed.username is not None or parsed.port not in (None, 443):
        raise ValueError("Download redirected outside trusted GitHub HTTPS domains")


def token_from_local_login():
    token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if token:
        return token.strip()
    if shutil.which("gh"):
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=20)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    # Read an existing credential only; never open a login prompt or print its output.
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never")
    try:
        result = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                                capture_output=True, text=True, env=env, timeout=20)
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if result.returncode == 0 and values.get("password"):
            return values["password"]
    except (OSError, subprocess.TimeoutExpired):
        pass
    raise ValueError("GitHub login missing. Use gh auth login, or set GH_TOKEN locally with Contents: write for the release repository")


def api(token, method, path, *, body=None, file=None, content_type="application/json"):
    url = path if path.startswith("https://") else "https://api.github.com" + path
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in {"api.github.com", "uploads.github.com"} or parsed.username is not None or parsed.port not in (None, 443):
        raise ValueError("Untrusted GitHub API/upload address")
    data = file if file is not None else json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "daily-consume-release-publisher"}
    if data is not None:
        headers["Content-Type"] = content_type
        headers["Content-Length"] = str(os.fstat(file.fileno()).st_size if file is not None else len(data))
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=120) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise ValueError("GitHub API response too large")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        try:
            message = json.loads(error.read(8192)).get("message", "Request failed")
        except (ValueError, UnicodeError):
            message = "Request failed"
        raise GithubError(error.code, message) from None


def open_public(url):
    check_public_url(url)
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "daily-consume-release-check"})
    return urllib.request.build_opener(PublicRedirect()).open(request, timeout=30)


def read_manifest(url, *, missing_ok=False):
    try:
        url += ("&" if "?" in url else "?") + "t=" + str(time.time_ns())
        with open_public(url) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError("Manifest exceeds 64 KiB")
        return json.loads(raw)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise GithubError(error.code, "Cannot download the public release manifest") from None


def verify_public(repo, manifest):
    fixed = f"https://github.com/{repo}/releases/latest/download/latest.json"
    if read_manifest(fixed) != manifest:
        raise ValueError("Latest manifest does not match this release; check latest-release selection/cache")
    sha = hashlib.sha256()
    total = 0
    with open_public(manifest["apkUrl"]) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            total += len(chunk)
            if total > manifest["size"]:
                raise ValueError("Public APK exceeds expected size")
            sha.update(chunk)
    if total != manifest["size"] or sha.hexdigest() != manifest["sha256"]:
        raise ValueError("Public APK size or SHA256 mismatch")
    print(f"Public manifest and APK verified ({total:,} bytes, SHA256 matched).")


def verify_asset(asset, size, sha):
    if asset.get("state") != "uploaded" or asset.get("size") != size or asset.get("digest") != "sha256:" + sha:
        raise ValueError("Release asset size/state/digest mismatch; no existing asset will be overwritten")


def ensure_asset(token, release, path, content_type):
    data_sha = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            data_sha.update(chunk)
    size = path.stat().st_size
    existing = next((a for a in release.get("assets", []) if a["name"] == path.name), None)
    if existing:
        verify_asset(existing, size, data_sha.hexdigest())
        print(f"Reusing identical asset: {path.name}")
        return
    if not release["draft"]:
        raise ValueError("Published release is missing assets; refusing to modify it")
    url = release["upload_url"].split("{", 1)[0] + "?" + urllib.parse.urlencode({"name": path.name})
    print(f"Uploading {path.name} ({size / 1048576:.2f} MiB)...", flush=True)
    with path.open("rb") as stream:
        uploaded = api(token, "POST", url, file=stream, content_type=content_type)
    verify_asset(uploaded, size, data_sha.hexdigest())


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=DEFAULT_REPO, help="Public release repository OWNER/REPO")
    parser.add_argument("--apk", type=Path, default=apk_tools.ROOT / "build/app/outputs/flutter-apk/app-release.apk")
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--java", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="Validate local APK only; no requests/uploads")
    parser.add_argument("--check-access", action="store_true", help="Read-only GitHub login/repository permission check")
    return parser.parse_args()


def main():
    args = arguments()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        raise ValueError("--repo must be OWNER/REPO")
    args.base_url = "https://github.com/" + args.repo
    if args.dry_run and args.check_access:
        raise ValueError("Choose either --dry-run or --check-access")
    token = None
    if not args.dry_run:
        token = token_from_local_login()
        repository = api(token, "GET", "/repos/" + args.repo)
        if repository.get("private") or repository.get("archived") or not repository.get("permissions", {}).get("push"):
            raise ValueError("Release repository must be public, writable and active")
        if args.check_access:
            user = api(token, "GET", "/user")
            print(f"GitHub login: {user['login']}; public writable repository: {args.repo}. No files changed.")
            return
    apk, _, manifest = apk_tools.inspect_apk(args)
    with zipfile.ZipFile(apk) as archive:
        embedded = json.loads(archive.read("assets/flutter_assets/assets/release_notes.json"))
    expected_source = f"https://github.com/{args.repo}/releases/latest/download/latest.json"
    if embedded.get("updateManifestUrl") != expected_source:
        raise ValueError("APK's bundled update source does not match --repo; rebuild with scripts/build_release.ps1")
    tag = f"v{manifest['versionName']}+{manifest['versionCode']}"
    manifest["apkUrl"] = f"https://github.com/{args.repo}/releases/download/{urllib.parse.quote(tag, safe='')}/app-release.apk"
    if args.dry_run:
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        print("Local APK checked; no requests or uploads made.")
        return
    fixed = f"https://github.com/{args.repo}/releases/latest/download/latest.json"
    previous = read_manifest(fixed, missing_ok=True)
    if previous and (previous["versionCode"] > manifest["versionCode"] or
                     previous["packageName"] != manifest["packageName"] or
                     previous.get("signingCertificateSha256") != manifest["signingCertificateSha256"]):
        raise ValueError("Published version is newer, or package/signing certificate differs")
    releases = api(token, "GET", f"/repos/{args.repo}/releases?per_page=100")
    release = next((r for r in releases if r["tag_name"] == tag), None)
    if previous and previous["versionCode"] == manifest["versionCode"] and release is None:
        raise ValueError("This version is already published under another tag")
    if release is None:
        # Upload into a draft so clients never discover incomplete assets.
        release = api(token, "POST", f"/repos/{args.repo}/releases", body={
            "tag_name": tag, "target_commitish": repository["default_branch"],
            "name": f"日常 {manifest['versionName']} ({manifest['versionCode']})",
            "body": "\n".join("- " + n for n in manifest["releaseNotes"]),
            "draft": True, "prerelease": False,
        })
        print("Draft release created; the previous latest release remains available.")
    if release.get("prerelease"):
        raise ValueError("Matching tag is a prerelease; use a distinct stable version")
    manifest["publishedAt"] = release["created_at"]
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
    if len(manifest_bytes) > 65536:
        raise ValueError("Final manifest exceeds 64 KiB; shorten the release notes")
    output = apk_tools.ROOT / "build/github-release" / str(manifest["versionCode"])
    output.mkdir(parents=True, exist_ok=True)
    manifest_file = output / "latest.json"
    manifest_file.write_bytes(manifest_bytes)
    # Upload the canonical asset name even when --apk points to a differently named APK.
    if apk.name != "app-release.apk":
        staged = output / "app-release.apk"
        shutil.copyfile(apk, staged)
        apk = staged
    ensure_asset(token, release, apk, "application/vnd.android.package-archive")
    ensure_asset(token, release, manifest_file, "application/json; charset=utf-8")
    ready = api(token, "GET", f"/repos/{args.repo}/releases/{release['id']}")
    if not {"app-release.apk", "latest.json"}.issubset({a["name"] for a in ready["assets"]}):
        raise ValueError("Draft assets incomplete; release was not published")
    # ponytail: run one publisher at a time; concurrent jobs need a release lock.
    now = read_manifest(fixed, missing_ok=True)
    if now != previous:
        raise ValueError("Latest release changed during upload; draft preserved for review")
    if ready["draft"]:
        ready = api(token, "PATCH", f"/repos/{args.repo}/releases/{release['id']}",
                    body={"draft": False, "prerelease": False, "make_latest": "true"})
    print(f"Release published: {ready['html_url']}", flush=True)
    verify_public(args.repo, manifest)
    print(f"Manifest: {fixed}")
    print(f"APK: {manifest['apkUrl']}")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    try:
        main()
    except Exception as error:
        # Never print credential helper output, headers or temporary signed redirect URLs.
        message = str(error) if isinstance(error, (ValueError, GithubError, FileNotFoundError)) else type(error).__name__
        print(f"Release failed: {message}", file=sys.stderr)
        sys.exit(1)
