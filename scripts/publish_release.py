"""Publish a signed APK, then latest.json. Credentials stay on this computer."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_KEY = "releases/android/latest.json"
DEFAULT_HOST = "https://daily-consume-app.oss-cn-beijing.aliyuncs.com"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, default=ROOT / "build/app/outputs/flutter-apk/app-release.apk")
    parser.add_argument("--sdk", type=Path, help="Android SDK directory; defaults to local.properties / ANDROID_HOME")
    parser.add_argument("--java", type=Path, help="java.exe used to verify the APK signature")
    parser.add_argument("--bucket", default="daily-consume-app")
    parser.add_argument("--region", default="cn-beijing")
    parser.add_argument("--endpoint", default="https://oss-cn-beijing.aliyuncs.com")
    parser.add_argument("--base-url", default=DEFAULT_HOST, help="HTTPS public download origin, with no path")
    parser.add_argument("--dry-run", action="store_true", help="Check local APK and print manifest; no requests/uploads")
    parser.add_argument("--check-access", action="store_true", help="Read-only authenticated check; does not upload")
    return parser.parse_args()


def client(args):
    try:
        import alibabacloud_oss_v2 as oss
    except ImportError:
        raise ValueError("Install dependencies: python -m pip install -r scripts/requirements.txt") from None
    if not os.getenv("OSS_ACCESS_KEY_ID") or not os.getenv("OSS_ACCESS_KEY_SECRET"):
        raise ValueError("Set OSS_ACCESS_KEY_ID and OSS_ACCESS_KEY_SECRET locally before publishing")
    cfg = oss.config.load_default()
    cfg.region = args.region
    cfg.endpoint = args.endpoint
    cfg.credentials_provider = oss.credentials.EnvironmentVariableCredentialsProvider()
    cfg.connect_timeout = 10
    cfg.readwrite_timeout = 60
    return oss, oss.Client(cfg)


def unwrap_error(error):
    # SDK V2 wraps service errors in OperationError.
    for _ in range(8):
        unwrap = getattr(error, "unwrap", None)
        if unwrap is None:
            break
        nested = unwrap()
        if nested is None or nested is error:
            break
        error = nested
    return error


def sdk_directory(args):
    if args.sdk:
        return args.sdk.resolve()
    props = ROOT / "android/local.properties"
    if props.exists():
        match = re.search(r"^sdk\.dir=(.+)$", props.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            return Path(match[1].strip().replace("\\\\", "\\").replace("\\:", ":"))
    sdk = os.getenv("ANDROID_HOME") or os.getenv("ANDROID_SDK_ROOT")
    if not sdk:
        raise ValueError("Use --sdk or set ANDROID_HOME")
    return Path(sdk)


def tools_directory(sdk):
    folders = [p for p in (sdk / "build-tools").iterdir() if re.fullmatch(r"\d+\.\d+\.\d+", p.name)]
    if not folders:
        raise ValueError("Android SDK Build-Tools are not installed")
    return max(folders, key=lambda p: tuple(map(int, p.name.split("."))))


def java_executable(args):
    if args.java:
        return str(args.java)
    java_home = os.getenv("JAVA_HOME")
    candidates = [Path(java_home) / "bin/java.exe"] if java_home else []
    if shutil.which("java"):
        candidates.append(Path(shutil.which("java")))
    candidates += [Path("E:/APPs/Android Studio/jbr/bin/java.exe"),
                   Path(os.getenv("ProgramFiles", "C:/Program Files")) / "Android/Android Studio/jbr/bin/java.exe"]
    for path in candidates:
        if path.is_file():
            return str(path)
    raise ValueError("Use --java <path-to-java.exe> or set JAVA_HOME to Android Studio's jbr directory")


def run_tool(command):
    completed = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace", timeout=60)
    if completed.returncode:
        raise ValueError(f"APK validation failed: {Path(command[0]).name}")
    return completed.stdout


def inspect_apk(args):
    apk = args.apk.resolve()
    if not apk.is_file() or not 0 < apk.stat().st_size <= 512 * 1024 * 1024:
        raise ValueError("APK missing or larger than 512 MiB")
    tools = tools_directory(sdk_directory(args))
    badging = run_tool([str(tools / ("aapt.exe" if os.name == "nt" else "aapt")), "dump", "badging", str(apk)])
    match = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not match:
        raise ValueError("Cannot read APK package/version metadata")
    package, code, version = match.groups()
    if package != "com.example.daily_consume" or int(code) <= 0 or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Unexpected package, versionCode or versionName")
    with zipfile.ZipFile(apk) as archive:
        entry = archive.getinfo("assets/flutter_assets/assets/release_notes.json")
        if entry.file_size > 65536:
            raise ValueError("Embedded release notes too large")
        embedded = json.loads(archive.read(entry).decode("utf-8"))
    notes = embedded.get("releaseNotes")
    if embedded.get("versionCode") != int(code) or embedded.get("versionName") != version:
        raise ValueError("APK version and assets/release_notes.json do not match; rebuild the APK")
    if not isinstance(notes, list) or not notes or any(not isinstance(n, str) or not n.strip() for n in notes) or len("".join(notes)) > 32000:
        raise ValueError("Release notes must be a non-empty list of strings, at most 32000 characters")
    verification = run_tool([java_executable(args), "-jar", str(tools / "lib/apksigner.jar"),
                             "verify", "--print-certs", str(apk)])
    certs = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]{64})", verification)
    if not certs:
        raise ValueError("APK signature could not be verified")
    sha = hashlib.sha256()
    with apk.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    key = f"releases/android/{version}+{code}/app-release.apk"
    manifest = dict(packageName=package, versionName=version, versionCode=int(code),
                    apkUrl=f"{args.base_url}/{urllib.parse.quote(key, safe='/')}", size=apk.stat().st_size,
                    sha256=sha.hexdigest(), signingCertificateSha256=sorted(c.lower() for c in certs),
                    releaseNotes=notes, publishedAt=datetime.now(timezone.utc).isoformat())
    return apk, key, manifest


def public_request(url, *, head=False):
    request = urllib.request.Request(url, method="HEAD" if head else "GET", headers={"Cache-Control": "no-cache"})
    try:
        return urllib.request.urlopen(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code == 400:
            try:
                code = ET.fromstring(error.read(8192)).findtext("Code")
            except ET.ParseError:
                code = None
            if code == "ApkDownloadForbidden":
                raise ValueError("OSS blocks APK downloads through its default domain; configure your own HTTPS domain and use --base-url") from None
        raise


def public_manifest(args):
    try:
        with public_request(f"{args.base_url}/{MANIFEST_KEY}?t={datetime.now().timestamp()}") as response:
            content = response.read(65537)
            if len(content) > 65536:
                raise ValueError("Remote manifest too large")
            return json.loads(content)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise ValueError(f"Cannot read public manifest: HTTP {error.code}; check object read permissions") from None


def publish(args, apk, key, manifest):
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
    if len(manifest_bytes) > 65536:
        raise ValueError("Final manifest exceeds the app's 64 KiB limit; shorten the release notes before publishing")
    oss, connection = client(args)
    previous = public_manifest(args)
    if previous:
        if previous.get("packageName") != manifest["packageName"]:
            raise ValueError("Remote manifest belongs to another application")
        if int(previous["versionCode"]) >= manifest["versionCode"]:
            raise ValueError("versionCode must be greater than the published version; refusing rollback/overwrite")
        if previous.get("signingCertificateSha256") != manifest["signingCertificateSha256"]:
            raise ValueError("Signing certificate differs from the previous release; cannot publish an in-place update")
    try:
        existing = connection.head_object(oss.HeadObjectRequest(bucket=args.bucket, key=key))
        if int(existing.content_length) != manifest["size"] or existing.metadata.get("sha256") != manifest["sha256"]:
            raise ValueError("This version's object already exists with different content; increase versionCode")
        print("Identical APK already uploaded; continuing manifest publication.")
    except Exception as error:
        cause = unwrap_error(error)
        if not isinstance(cause, oss.exceptions.ServiceError) or cause.status_code != 404 or cause.code != "NoSuchKey":
            raise
        print(f"Uploading {manifest['versionName']} ({manifest['size'] / 1048576:.1f} MiB)...")
        connection.put_object_from_file(oss.PutObjectRequest(
            bucket=args.bucket, key=key, acl="public-read", forbid_overwrite=True,
            content_type="application/vnd.android.package-archive", cache_control="public, max-age=31536000, immutable",
            metadata={"sha256": manifest["sha256"]}), str(apk))
    remote = connection.head_object(oss.HeadObjectRequest(bucket=args.bucket, key=key))
    if int(remote.content_length) != manifest["size"] or remote.metadata.get("sha256") != manifest["sha256"]:
        raise ValueError("Uploaded APK metadata mismatch; latest.json was not changed")
    # Verify anonymous downloads and actual bytes before any device can discover this version.
    sha = hashlib.sha256()
    downloaded = 0
    with public_request(manifest["apkUrl"]) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            downloaded += len(chunk)
            if downloaded > manifest["size"]:
                raise ValueError("Public APK size mismatch; latest.json was not changed")
            sha.update(chunk)
    if downloaded != manifest["size"] or sha.hexdigest() != manifest["sha256"]:
        raise ValueError("Public APK hash mismatch; latest.json was not changed")
    # ponytail: one publisher at a time; add conditional OSS writes for concurrent release jobs.
    now = public_manifest(args)
    if now != previous:
        raise ValueError("Remote version changed during upload; refusing to overwrite latest.json")
    connection.put_object(oss.PutObjectRequest(
        bucket=args.bucket, key=MANIFEST_KEY, acl="public-read", content_type="application/json; charset=utf-8",
        cache_control="no-store, no-cache, must-revalidate", body=manifest_bytes))
    if public_manifest(args) != manifest:
        raise ValueError("Manifest uploaded but public read-back failed; check OSS/CDN cache")
    print(f"Published: {args.base_url}/{MANIFEST_KEY}")
    print(f"APK: {manifest['apkUrl']}")


def main():
    args = arguments()
    args.base_url = args.base_url.rstrip("/")
    origin = urllib.parse.urlsplit(args.base_url)
    if origin.scheme != "https" or not origin.hostname or origin.path or origin.query or origin.fragment or origin.username:
        raise ValueError("--base-url must be an HTTPS origin, without a path or credentials")
    if args.dry_run and args.check_access:
        raise ValueError("Choose either --dry-run or --check-access")
    if args.check_access:
        oss, connection = client(args)
        try:
            result = connection.head_object(oss.HeadObjectRequest(bucket=args.bucket, key=MANIFEST_KEY))
            print(f"Authenticated OSS read OK (HTTP {result.status_code}); no files changed.")
        except Exception as error:
            cause = unwrap_error(error)
            if isinstance(cause, oss.exceptions.ServiceError) and cause.status_code == 404 and cause.code == "NoSuchKey":
                print("Authenticated OSS read OK; latest.json does not exist yet. No files changed.")
            else:
                raise
        return
    apk, key, manifest = inspect_apk(args)
    if args.dry_run:
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        print("Local APK validated; no requests or uploads made.")
    else:
        publish(args, apk, key, manifest)


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    try:
        main()
    except Exception as error:
        # Do not dump SDK request headers or credentials into CI logs.
        error = unwrap_error(error)
        if isinstance(error, (ValueError, FileNotFoundError, KeyError, zipfile.BadZipFile)):
            message = str(error)
        elif getattr(error, "status_code", None):
            message = f"OSS HTTP {error.status_code} ({error.code}); check bucket and RAM permissions"
        else:
            message = f"{type(error).__name__}; check network, bucket and RAM permissions"
        print(f"Release failed: {message}", file=sys.stderr)
        sys.exit(1)
