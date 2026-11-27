"""FAT32 images for the tests: make one, read one back, and check it.

Independent of the driver: written from the FAT specification, used to
check what the driver leaves on the card.
"""
import struct

SEC = 512
EOC = 0x0FFFFFFF


def mkfs(sectors=81920, spc=1, nfats=2, partition=True, ptype=0x0C,
         fsinfo=True, label=b"TESTCARD   "):
    """A fresh FAT32 image: an MBR partition (or the whole image, when
    partition is False) with an empty root directory in cluster 2."""
    part = 2048 if partition else 0
    total = part + sectors
    img = bytearray(total * SEC)
    rsv = 32
    # FAT size: enough entries for the clusters
    fatsz = 1
    while True:
        clusters = (sectors - rsv - nfats * fatsz) // spc
        if (clusters + 2) * 4 <= fatsz * SEC:
            break
        fatsz += 1
    if partition:
        mbr = bytearray(SEC)
        e = 0x1BE
        mbr[e + 4] = ptype
        struct.pack_into("<II", mbr, e + 8, part, sectors)
        mbr[510:512] = b"\x55\xAA"
        img[0:SEC] = mbr
    bs = bytearray(SEC)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", bs, 11, SEC, spc, rsv, nfats, 0, 0,
                     0xF8, 0, 63, 255, part, sectors)
    struct.pack_into("<IHHIHH", bs, 36, fatsz, 0, 0, 2, 1 if fsinfo else 0, 6)
    bs[64] = 0x80
    bs[66] = 0x29
    struct.pack_into("<I", bs, 67, 0x12345678)
    bs[71:82] = label
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xAA"
    o = part * SEC
    img[o:o + SEC] = bs
    img[o + 6 * SEC:o + 7 * SEC] = bs          # backup boot sector
    if fsinfo:
        fi = bytearray(SEC)
        fi[0:4] = b"RRaA"
        fi[484:488] = b"rrAa"
        struct.pack_into("<II", fi, 488, clusters - 1, 3)
        fi[510:512] = b"\x55\xAA"
        img[o + SEC:o + 2 * SEC] = fi
    fat = bytearray(fatsz * SEC)
    struct.pack_into("<III", fat, 0, 0x0FFFFFF8, EOC, EOC)
    for n in range(nfats):
        f = (part + rsv + n * fatsz) * SEC
        img[f:f + len(fat)] = fat
    return img


class Volume:
    def __init__(self, img):
        self.img = img
        sec0 = img[0:SEC]
        self.part = 0
        for i in range(4):
            if sec0[0x1BE + i * 16 + 4] in (0x0B, 0x0C):
                self.part = struct.unpack_from("<I", sec0, 0x1BE + i * 16 + 8)[0]
                break
        b = self.part * SEC
        self.spc = img[b + 13]
        self.rsv = struct.unpack_from("<H", img, b + 14)[0]
        self.nfats = img[b + 16]
        self.totsec = struct.unpack_from("<I", img, b + 32)[0]
        self.fatsz = struct.unpack_from("<I", img, b + 36)[0]
        self.root = struct.unpack_from("<I", img, b + 44)[0]
        self.fsinfo = struct.unpack_from("<H", img, b + 48)[0]
        self.fat0 = self.part + self.rsv
        self.data0 = self.fat0 + self.nfats * self.fatsz
        self.nclus = min((self.totsec - (self.data0 - self.part)) // self.spc + 2,
                         self.fatsz * SEC // 4)
        self.cbytes = self.spc * SEC

    def fat(self, c, n=0):
        o = (self.fat0 + n * self.fatsz) * SEC + c * 4
        return struct.unpack_from("<I", self.img, o)[0] & 0x0FFFFFFF

    def valid(self, c):
        return 2 <= c < self.nclus

    def chain(self, c):
        out = []
        seen = set()
        while self.valid(c):
            if c in seen:
                raise ValueError(f"cluster loop at {c}")
            seen.add(c)
            out.append(c)
            c = self.fat(c)
        return out

    def cluster(self, c):
        o = (self.data0 + (c - 2) * self.spc) * SEC
        return self.img[o:o + self.cbytes]

    def entries(self, dircl):
        """(name, attr, cluster, size, slot) for each live short entry,
        and the raw entries, of a directory."""
        data = b"".join(self.cluster(c) for c in self.chain(dircl))
        raw = [data[i:i + 32] for i in range(0, len(data), 32)]
        out = []
        for slot, e in enumerate(raw):
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            name = e[0:8].decode("latin-1").rstrip()
            ext = e[8:11].decode("latin-1").rstrip()
            full = name + ("." + ext if ext else "")
            cl = struct.unpack_from("<H", e, 20)[0] << 16 | struct.unpack_from("<H", e, 26)[0]
            out.append((full, e[11], cl, struct.unpack_from("<I", e, 28)[0], slot))
        return out, raw

    def read(self, cl, size):
        return b"".join(self.cluster(c) for c in self.chain(cl))[:size]

    def tree(self):
        """{path: ("dir", None) or ("file", bytes)} for the whole volume."""
        out = {}

        def walk(dircl, prefix):
            ents, _ = self.entries(dircl)
            for name, attr, cl, size, _ in ents:
                if name in (".", ".."):
                    continue
                path = prefix + name
                if attr & 0x10:
                    out[path] = ("dir", None)
                    walk(cl, path + "/")
                else:
                    out[path] = ("file", self.read(cl, size) if cl else b"")
        walk(self.root, "")
        return out

    def check(self):
        """A list of problems: cross-linked or leaked clusters, chains that
        do not fit the sizes, bad "." / "..", orphan long names, FAT copies
        that differ, a wrong FSInfo free count."""
        problems = []
        owner = {}

        def own(chain, who):
            for c in chain:
                if c in owner:
                    problems.append(f"cluster {c} in {owner[c]} and {who}")
                owner[c] = who

        def walk(dircl, parentcl, path):
            try:
                own(self.chain(dircl), path or "/")
            except ValueError as e:
                problems.append(f"{path}: {e}")
                return
            ents, raw = self.entries(dircl)
            # long-name runs must end at an entry with their checksum
            run = []
            for e in raw:
                if e[0] == 0:
                    break
                if e[0] != 0xE5 and e[11] == 0x0F:
                    run.append(e)
                    continue
                if run and e[0] != 0xE5:
                    s = 0
                    for ch in e[0:11]:
                        s = (((s & 1) << 7) | (s >> 1)) + ch & 0xFF
                    if any(r[13] != s for r in run):
                        problems.append(f"{path}: long name before {e[0:11]!r} does not match it")
                elif run:
                    problems.append(f"{path}: orphan long-name entries")
                run = []
            if run:
                problems.append(f"{path}: orphan long-name entries at the end")
            names = [n for n, *_ in ents]
            if len(names) != len(set(names)):
                problems.append(f"{path}: duplicate names {names}")
            if dircl != self.root:
                dots = {n: cl for n, _, cl, _, _ in ents if n in (".", "..")}
                if dots.get(".") != dircl:
                    problems.append(f"{path}: '.' is {dots.get('.')}, not {dircl}")
                want = 0 if parentcl == self.root else parentcl
                if dots.get("..") != want:
                    problems.append(f"{path}: '..' is {dots.get('..')}, not {want}")
            for name, attr, cl, size, _ in ents:
                if name in (".", ".."):
                    continue
                p = path + "/" + name if path else name
                if attr & 0x10:
                    walk(cl, dircl, p)
                    continue
                try:
                    ch = self.chain(cl) if cl else []
                except ValueError as e:
                    problems.append(f"{p}: {e}")
                    continue
                need = -(-size // self.cbytes)
                if len(ch) != need:
                    problems.append(f"{p}: {len(ch)} clusters for {size} bytes")
                if cl and self.fat(ch[-1]) < 0x0FFFFFF8:
                    problems.append(f"{p}: chain does not end with end-of-chain")
                own(ch, p)
        walk(self.root, None, "")
        used = [c for c in range(2, self.nclus) if self.fat(c) != 0]
        leaked = [c for c in used if c not in owner]
        if leaked:
            problems.append(f"{len(leaked)} clusters in use by nothing: {leaked[:10]}")
        if self.nfats == 2:
            a = self.img[self.fat0 * SEC:(self.fat0 + self.fatsz) * SEC]
            b = self.img[(self.fat0 + self.fatsz) * SEC:(self.fat0 + 2 * self.fatsz) * SEC]
            if a != b:
                problems.append("the two FATs differ")
        if self.fsinfo:
            o = (self.part + self.fsinfo) * SEC
            count = struct.unpack_from("<I", self.img, o + 488)[0]
            actual = self.nclus - 2 - len(used)
            if count != 0xFFFFFFFF and count != actual:
                problems.append(f"FSInfo free count {count}, actually {actual}")
        return problems

    def free(self):
        return sum(1 for c in range(2, self.nclus) if self.fat(c) == 0)


def lfn_entries(longname, short11):
    """Long-name entries (in disk order) for a short name, as Windows would
    write them."""
    s = 0
    for ch in short11:
        s = (((s & 1) << 7) | (s >> 1)) + ch & 0xFF
    units = [ord(c) for c in longname] + [0]
    while len(units) % 13:
        units.append(0xFFFF)
    parts = [units[i:i + 13] for i in range(0, len(units), 13)]
    out = []
    for n, part in enumerate(parts, 1):
        e = bytearray(32)
        e[0] = n | (0x40 if n == len(parts) else 0)
        e[11] = 0x0F
        e[13] = s
        for i, u in enumerate(part):
            off = (1 + 2 * i) if i < 5 else (14 + 2 * (i - 5)) if i < 11 else (28 + 2 * (i - 11))
            struct.pack_into("<H", e, off, u)
        out.append(bytes(e))
    return list(reversed(out))
