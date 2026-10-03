#!/usr/bin/env python3
"""
Uploads workplace-ai-bundle.tar.gz to Google Drive using Google Drive API v3.
"""
import os
import sys
from pathlib import Path

BUNDLE_PATH = Path(__file__).resolve().parent / "workplace-ai-bundle.tar.gz"
if not BUNDLE_PATH.exists():
    BUNDLE_PATH = Path(os.path.expanduser("~/workplace-ai-bundle.tar.gz"))

def main():
    if not BUNDLE_PATH.exists():
        print(f"Error: Archive not found at {BUNDLE_PATH}")
        sys.exit(1)

    print("Checking Google Drive authentication...")
    try:
        import google.auth
        from google.auth.transport.requests import Request
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload

        creds, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/drive.file", "https://www.googleapis.com/auth/drive"]
        )

        if not creds.valid:
            if creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                raise Exception("Credentials are invalid or lack Drive scope.")

        service = build("drive", "v3", credentials=creds)

        parent_id = sys.argv[1] if len(sys.argv) > 1 else None
        file_metadata = {"name": "workplace-ai-bundle.tar.gz"}
        if parent_id:
            file_metadata["parents"] = [parent_id]

        media = MediaFileUpload(
            str(BUNDLE_PATH),
            mimetype="application/gzip",
            resumable=True
        )

        print(f"Uploading {BUNDLE_PATH} ({BUNDLE_PATH.stat().st_size / (1024*1024):.2f} MB)...")
        file = service.files().create(
            body=file_metadata,
            media_body=media,
            fields="id, name, webViewLink",
            supportsAllDrives=True
        ).execute()

        file_id = file.get("id")
        print("\n" + "=" * 60)
        print("✓ Upload successful!")
        print(f"File ID: {file_id}")
        print(f"View Link: {file.get('webViewLink')}")
        print("=" * 60)
        print("\nYour terminal one-liner for offline/no-github machines:")
        print(f'curl -sSL "https://drive.usercontent.google.com/download?id={file_id}&export=download" -o bundle.tar.gz && tar -xzf bundle.tar.gz && cd workplace-setup && bash setup_and_run_smolagent.sh\n')

    except Exception as e:
        print(f"\nAuthentication required for Google Drive API: {e}")
        print("\nTo authenticate CLI upload, run:")
        print("  gcloud auth application-default login --scopes=https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/drive\n")
        print("Or simply drag-and-drop the archive via browser:")
        print(f"  File location: {BUNDLE_PATH}")

if __name__ == "__main__":
    main()
