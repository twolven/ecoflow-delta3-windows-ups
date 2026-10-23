"""Prepare an encrypted ID for the protected SYSTEM installation, without printing it."""
from pathlib import Path
from secure_store import load_user_id, save_user_id

root = Path(__file__).resolve().parent
save_user_id(root / "machine-user-id.dpapi", load_user_id(root / "user-id.dpapi"), machine=True)
print("Prepared encrypted account ID for the SYSTEM bridge.")
