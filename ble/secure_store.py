"""Protect the EcoFlow user ID with this Windows user's DPAPI key."""
import ctypes
from ctypes import wintypes
from pathlib import Path


class Blob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def transform(data: bytes, protect: bool, machine: bool = False) -> bytes:
    source_buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(source_buffer, ctypes.POINTER(ctypes.c_ubyte)))
    output = Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    function = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                         ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
                         ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    flags = 1 | (4 if protect and machine else 0)
    if not function(ctypes.byref(source), None, None, None, None, flags, ctypes.byref(output)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output.data, output.size)
    finally:
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree.restype = ctypes.c_void_p
        kernel.LocalFree(output.data)


def save_user_id(path: Path, user_id: str, machine: bool = False):
    temporary = path.with_suffix(".tmp")
    temporary.write_bytes(transform(user_id.encode("utf-8"), True, machine=machine))
    temporary.replace(path)


def load_user_id(path: Path) -> str:
    return transform(path.read_bytes(), False).decode("utf-8")
