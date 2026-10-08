# Copyright (c) 2026 PlayGTA5. BSD-3-Clause; see LICENSE.
"""Reproduce vendored sources from official downloaded archives.

Usage: python3 tool/vendor_sources.py BOOST_ARCHIVE LIBTORRENT_RELEASE_ARCHIVE
Both inputs are checked against upstream SHA-256 before any output is written.
"""
import gzip
import hashlib
from pathlib import Path
import shutil
import sys
import tarfile

BOOST_SHA = 'be0d91732d5b0cc6fbb275c7939974457e79b54d6f07ce2e3dfdd68bef883b0b'
TORRENT_SHA = '5e2e79129823b7ea48721164c32b5aaf83d3fd733b5502100f6705b29f27bb02'
HEADERS_SHA = 'bed57bbbbd7f4bc72f0ce53dbd08cadccc7b96c81670e4d2b899a267259c2f72'


def verify(path, expected):
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f'Checksum mismatch: {path}: {actual}')


def main():
    boost, torrent = sys.argv[1:]
    verify(boost, BOOST_SHA)
    verify(torrent, TORRENT_SHA)
    vendor = Path(__file__).resolve().parents[1] / 'native' / 'vendor'
    vendor.mkdir(parents=True, exist_ok=True)
    output = vendor / 'boost-1.85.0-headers.tar.gz'
    with tarfile.open(boost, 'r:gz') as source, output.open('wb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as target:
                for member in source:
                    if member.name.startswith('boost_1_85_0/boost/') or member.name == 'boost_1_85_0/LICENSE_1_0.txt':
                        member.uid = member.gid = 0
                        member.uname = member.gname = ''
                        member.mtime = 0
                        target.addfile(member, source.extractfile(member) if member.isfile() else None)
    verify(output, HEADERS_SHA)
    shutil.copyfile(torrent, vendor / 'libtorrent-2.0.15.tar.gz')


if __name__ == '__main__':
    main()
