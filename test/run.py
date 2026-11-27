#!/usr/bin/env python3
"""File system tests for sdcard6502, run in kim1emu.

fstest.bin (see fstest.c) runs a script of file operations against the
driver.  Normally the driver's sector reads and writes are done here, at
breakpoints, for speed; --real runs them through the emulated SD card and
the bit-banged SPI instead.  Every result is compared with a model of the
file system, and afterwards the card image is checked with fatfs.py.

usage: run.py [--real] [--seed N] [--ops N] [--cardtype sdhc|sdsc|sdsc-v1]
"""
import argparse
import random
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fatfs  # noqa: E402

KIM1EMU = None
for up in HERE.parents:
    if (up / "kim1emu" / "kim1.py").exists():
        KIM1EMU = up
        break

ERR = dict(io=1, notfound=2, exists=3, full=4, notempty=5, badname=6,
           isdir=7, notdir=8, access=9, range=10)


def labels():
    out = {}
    for line in (HERE / "fstest.lbl").read_text().split("\n"):
        parts = line.split()
        if len(parts) == 3:
            out[parts[2].lstrip(".")] = int(parts[1], 16)
    return out


def run_script(img, script, real=False, cardtype="sdhc", max_steps=400_000_000):
    """Run the script lines; return the result lines.  img is updated."""
    sys.path.insert(0, str(KIM1EMU))
    from kim1emu.kim1 import KIM1Emulator
    lab = labels()
    emu = KIM1Emulator(rom_002=(KIM1EMU / "kim1emu/6530-002.bin").read_bytes(),
                       rom_003=(KIM1EMU / "kim1emu/6530-003.bin").read_bytes())
    emu.set_sd_interface("sdcard6502")
    emu.bus.io.sd.card_type = cardtype
    emu.bus.io.load_sd_image(bytes(img))
    emu.reset()
    emu.load_binary(HERE / "fstest.bin", 0x2000)
    text = ("\n".join(script) + "\n").encode()
    assert len(text) < 0x800, "script too long"
    ram = emu.bus.ram
    ram[0x9000:0x9000 + len(text) + 1] = text + b"\0"
    emu.set_pc(0x2000)
    done = lab["_t_done"]
    rd, wr = lab["sd_readsector"], lab["sd_writesector"]
    zsec, zadr = lab["zp_sd_currentsector"], lab["zp_sd_address"]
    emu.breakpoints = {done} if real else {done, rd, wr}
    cpu = emu.cpu
    steps = 0
    sectors = [0, 0]
    while steps < max_steps:
        steps += emu.run(max_steps=max_steps - steps)
        pc = cpu.pc
        if pc == done:
            break
        if pc in (rd, wr):
            lba = struct.unpack_from("<I", ram, zsec)[0]
            adr = ram[zadr] | ram[zadr + 1] << 8
            if pc == rd:
                ram[adr:adr + 512] = img[lba * 512:lba * 512 + 512]
                sectors[0] += 1
            else:
                img[lba * 512:lba * 512 + 512] = ram[adr:adr + 512]
                sectors[1] += 1
            cpu.p &= ~0x01                      # C=0: done
            lo = ram[0x100 + ((cpu.sp + 1) & 0xFF)]
            hi = ram[0x100 + ((cpu.sp + 2) & 0xFF)]
            cpu.sp = (cpu.sp + 2) & 0xFF
            cpu.pc = ((hi << 8 | lo) + 1) & 0xFFFF
            continue
        raise RuntimeError(f"stopped at ${pc:04X}: {emu.last_error}")
    else:
        raise RuntimeError("did not finish")
    if real:
        img[:] = emu.bus.io.export_sd_image()[:len(img)]
    out = bytes(ram[0x8000:0x9000]).split(b"\0")[0].decode("latin-1")
    return out.rstrip("\n").split("\n"), steps, sectors


# ---------------------------------------------------------------------------
# A model of the file system, giving the result each command should have.

def pattern(n, seed):
    return bytes((seed * 31 + i * 7 + (i >> 8) * 3) & 0xFF for i in range(n))


def sums(data):
    s1 = s2 = 0
    for b in data:
        s1 = (s1 + b) & 0xFFFF
        s2 = (s2 + s1) & 0xFFFF
    return s1, s2


class Model:
    def __init__(self):
        self.files = {}         # path (upper case) -> bytearray
        self.dirs = {""}
        self.handles = {}       # n -> [path, pos, mode]
        self.dsize = {}         # sizes in the directory entries, which
                                # change when a file is closed

    @staticmethod
    def split(path):
        parts = [p for p in path.upper().split("/") if p]
        return parts

    @staticmethod
    def valid(p):
        if p in (".", ".."):
            return True
        bad = set('"*+,/:;<=>?[\\]|') | {chr(c) for c in range(33)} | {chr(127)}
        base, dot, ext = p.partition(".")
        return (0 < len(base) <= 8 and len(ext) <= 3 and "." not in ext
                and not (set(base + ext) & bad))

    def resolve(self, path):
        """(error, parent, name, full) for a path"""
        parts = self.split(path)
        out = []
        for i, p in enumerate(parts):
            if not self.valid(p):
                return "badname", None, None, None
            if p == ".":
                continue
            if p == "..":
                if out:
                    out.pop()
                continue
            if i < len(parts) - 1:
                full = "/".join(out + [p])
                if full in self.files:
                    return "notdir", None, None, None
                if full not in self.dirs:
                    return "notfound", None, None, None
            out.append(p)
        if not out:
            return None, None, None, ""
        return None, "/".join(out[:-1]), out[-1], "/".join(out)

    def size(self, p):
        return self.dsize.get(p, len(self.files[p]))

    def cmd(self, c):
        w = c.split()
        op = w[0]
        if op == "init":
            return "0"
        if op == "open":
            h, path, mode = int(w[1]), w[2], w[3]
            err, parent, name, full = self.resolve(path)
            if err:
                return str(ERR[err])
            if full == "":
                return str(ERR["isdir"])
            if full in self.dirs:
                return str(ERR["exists" if "x" in mode else "isdir"])
            if full in self.files:
                if "x" in mode:
                    return str(ERR["exists"])
                if "w" in mode and "t" in mode:
                    self.files[full] = bytearray()
            else:
                if "c" not in mode:
                    return str(ERR["notfound"])
                if "w" not in mode:
                    return str(ERR["access"])
                self.files[full] = bytearray()
                self.dsize[full] = 0
            pos = len(self.files[full]) if "a" in mode else 0
            self.handles[h] = [full, pos, mode]
            return "0"
        if op in ("write", "read", "seek", "tell", "close"):
            h = int(w[1])
            hd = self.handles.get(h)
            if op == "close":
                if not hd:
                    return str(ERR["access"])
                del self.handles[h]
                self.dsize[hd[0]] = len(self.files[hd[0]])
                return "0"
            if op == "tell":
                return f"0 {hd[1]} {len(self.files[hd[0]])}"
            if op == "seek":
                if not hd:
                    return str(ERR["access"])
                pos = int(w[2])
                if pos > len(self.files[hd[0]]):
                    return str(ERR["range"])
                hd[1] = pos
                return "0"
            n = int(w[2])
            if op == "write":
                if not hd or "w" not in hd[2]:
                    return f"{ERR['access']} 0"
                data = self.files[hd[0]]
                data[hd[1]:hd[1] + n] = pattern(n, int(w[3]))
                hd[1] += n
                return f"0 {n}"
            if not hd or "r" not in hd[2]:
                return f"{ERR['access']} 0 0 0"
            data = self.files[hd[0]][hd[1]:hd[1] + n]
            hd[1] += len(data)
            return "0 %d %d %d" % ((len(data),) + sums(data))
        if op == "del":
            err, parent, name, full = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if full == "":
                return str(ERR["access"])
            if full in self.dirs:
                return str(ERR["isdir"])
            if full not in self.files:
                return str(ERR["notfound"])
            del self.files[full]
            self.dsize.pop(full, None)
            return "0"
        if op == "mkdir":
            err, parent, name, full = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if full == "" or full in self.dirs or full in self.files:
                return str(ERR["exists"])
            self.dirs.add(full)
            return "0"
        if op == "rmdir":
            err, parent, name, full = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if full == "":
                return str(ERR["access"])
            if full in self.files:
                return str(ERR["notdir"])
            if full not in self.dirs:
                return str(ERR["notfound"])
            if any(p.startswith(full + "/") for p in list(self.files) + list(self.dirs)):
                return str(ERR["notempty"])
            self.dirs.remove(full)
            return "0"
        if op == "mv":
            err, parent, name, old = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if old == "":
                return str(ERR["access"])
            if old not in self.files and old not in self.dirs:
                return str(ERR["notfound"])
            err, parent, name, new = self.resolve(w[2])
            if err:
                return str(ERR[err])
            if new == "":
                return str(ERR["exists"])
            if old in self.dirs and (parent + "/").startswith(old + "/"):
                return str(ERR["access"])
            if new in self.files or new in self.dirs:
                return str(ERR["exists"])
            if old in self.files:
                self.files[new] = self.files.pop(old)
                self.dsize[new] = self.dsize.pop(old, len(self.files[new]))
            else:
                for p in sorted(self.dirs):
                    if p == old or p.startswith(old + "/"):
                        self.dirs.remove(p)
                        self.dirs.add(new + p[len(old):])
                for p in list(self.files):
                    if p.startswith(old + "/"):
                        self.files[new + p[len(old):]] = self.files.pop(p)
                        self.dsize[new + p[len(old):]] = self.dsize.pop(p, 0)
            return "0"
        if op == "ls":
            err, parent, name, full = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if full in self.files:
                return str(ERR["notdir"])
            if full not in self.dirs:
                return str(ERR["notfound"])
            pre = full + "/" if full else ""
            items = []
            for p, d in self.files.items():
                if p.startswith(pre) and "/" not in p[len(pre):]:
                    items.append(f"{p[len(pre):].lower()}/{self.size(p)}/0")
            for p in self.dirs:
                if p and p.startswith(pre) and "/" not in p[len(pre):]:
                    items.append(f"{p[len(pre):].lower()}/0/1")
            return " ".join(["0"] + sorted(items))
        if op == "stat":
            err, parent, name, full = self.resolve(w[1])
            if err:
                return str(ERR[err])
            if full == "":
                return "0 / 1 0"
            if full in self.dirs:
                return f"0 {name.lower()} 1 0"
            if full in self.files:
                return f"0 {name.lower()} 0 {self.size(full)}"
            return str(ERR["notfound"])
        if op == "free":
            return "0 ?"
        if op in ("sync",):
            return "0"
        raise ValueError(c)


def normalise(line):
    """ls output in a fixed order"""
    w = line.split()
    if len(w) > 1 and "/" in w[1]:
        return " ".join([w[0]] + sorted(w[1:]))
    return line


# ---------------------------------------------------------------------------
# Tests

def check_run(name, img, script, model=None, real=False, cardtype="sdhc", expect=None):
    model = model or Model()
    out, steps, sectors = run_script(img, script, real=real, cardtype=cardtype)
    bad = 0
    for i, c in enumerate(script):
        want = expect[i] if expect else model.cmd(c)
        got = out[i] if i < len(out) else "(nothing)"
        if c.split()[0] == "free":
            want = got if got.startswith("0 ") else "0 ?"
        if normalise(got) != normalise(want):
            if bad < 10:
                print(f"  {name}: {c!r}: got {got!r}, want {want!r}")
            bad += 1
    vol = fatfs.Volume(img)
    problems = vol.check()
    for p in problems:
        print(f"  {name}: image: {p}")
    tree = vol.tree()
    want = {p: ("dir", None) for p in model.dirs if p}
    want.update({p: ("file", bytes(d)) for p, d in model.files.items()})
    if not model.handles:
        for p in sorted(set(tree) | set(want)):
            if tree.get(p) != want.get(p):
                print(f"  {name}: image: {p}: {tree.get(p, ('missing',))[0]} "
                      f"(want {want.get(p, ('missing',))[0]})")
                bad += 1
    ok = not bad and not problems
    print(f"{'ok  ' if ok else 'FAIL'} {name}  ({len(script)} commands, "
          f"{steps} instructions, {sectors[0]} reads, {sectors[1]} writes)")
    return ok


def basic(args):
    s = ["init",
         "ls /",
         "open 0 hello.txt wc", "write 0 100 1", "tell 0", "close 0",
         "open 0 hello.txt r", "read 0 200", "read 0 10", "close 0",
         "stat hello.txt", "stat nothere", "open 1 nothere r",
         "mkdir sub", "mkdir sub", "mkdir sub/deeper",
         "open 1 sub/deeper/a.bin wc", "write 1 1500 2", "write 1 700 3", "close 1",
         "open 1 sub/deeper/a.bin r", "seek 1 1000", "read 1 600", "seek 1 0",
         "read 1 2048", "read 1 2048", "seek 1 5000", "close 1",
         "ls sub", "ls sub/deeper", "ls hello.txt",
         "open 2 hello.txt wa", "write 2 50 4", "close 2",
         "open 2 hello.txt wt", "write 2 10 5", "close 2",
         "open 2 hello.txt wcx",
         "mv hello.txt sub/hi.txt", "mv sub/hi.txt sub/deeper/hi.txt",
         "mv sub sub/deeper/x", "mv sub top", "rmdir top", "del top/deeper/a.bin",
         "del top/deeper/hi.txt", "rmdir top/deeper", "rmdir top/deeper",
         "ls top", "rmdir top", "ls /",
         "open 3 bad*name wc", "open 3 toolongname.txt wc", "open 3 a.long wc",
         "mkdir nofile/x", "open 3 x/../y.txt wc", "close 3", "ls .",
         "free", "sync"]
    img = fatfs.mkfs(spc=args.spc)
    return check_run("basic", img, s, real=args.real, cardtype=args.cardtype)


def growth(args):
    # 40 files in a directory: it grows past a cluster; then delete half
    # and add more, which reuses the free entries.
    s = ["init", "mkdir d"]
    for i in range(40):
        s.append(f"open 0 d/f{i}.dat wc")
        s.append(f"write 0 {i * 37 % 600} {i}")
        s.append("close 0")
    s.append("ls d")
    img = fatfs.mkfs(spc=args.spc)
    model = Model()
    ok = check_run("dir growth", img, s, model, real=args.real, cardtype=args.cardtype)
    s = ["init"] + [f"del d/f{i}.dat" for i in range(0, 40, 2)]
    for i in range(10):
        s += [f"open 0 d/g{i}.dat wc", f"write 0 {i * 101} {i}", "close 0"]
    s.append("ls d")
    ok &= check_run("dir reuse", img, s, model, real=args.real, cardtype=args.cardtype)
    vol = fatfs.Volume(img)
    d = [e for e in vol.entries(vol.root)[0] if e[0] == "D"][0]
    print(f"     directory d: {len(vol.chain(d[2]))} clusters")
    return ok


def bigfile(args):
    # a file over 64 KB, read back in pieces, then appended to
    s = ["init", "open 0 big.dat wc"]
    for i in range(40):
        s.append(f"write 0 2000 {i}")
    s += ["tell 0", "close 0", "open 0 big.dat r", "seek 0 70000", "read 0 2000",
          "seek 0 65530", "read 0 20", "close 0", "open 0 big.dat wa",
          "write 0 333 9", "tell 0", "close 0", "stat big.dat"]
    img = fatfs.mkfs(spc=args.spc)
    return check_run("big file", img, s, real=args.real, cardtype=args.cardtype)


def multi(args):
    # several files open at once, written in turn
    s = ["init"] + [f"open {h} m{h}.dat wc" for h in range(4)]
    for r in range(6):
        for h in range(4):
            s.append(f"write {h} {(r * 4 + h) * 53 % 700 + 1} {r * 4 + h}")
    s += [f"close {h}" for h in range(4)]
    s += ["open 0 m0.dat r", "open 1 m3.dat r", "read 0 900", "read 1 900",
          "read 0 2048", "read 1 2048", "close 0", "close 1"]
    img = fatfs.mkfs(spc=args.spc)
    return check_run("multiple open files", img, s, real=args.real, cardtype=args.cardtype)


def longnames(args):
    # files with long names (as a PC writes them): deleting or renaming
    # one removes its long-name entries too.
    img = fatfs.mkfs(spc=args.spc)
    vol = fatfs.Volume(img)
    root = (vol.data0 + (vol.root - 2) * vol.spc) * fatfs.SEC
    ents = []
    for i, (short, long) in enumerate([(b"LONGFI~1TXT", "Long file name one.txt"),
                                       (b"LONGFI~2TXT", "Long file name two.txt")]):
        ents += fatfs.lfn_entries(long, short)
        e = bytearray(32)
        e[0:11] = short
        e[11] = 0x20
        ents.append(bytes(e))
    img[root:root + 32 * len(ents)] = b"".join(ents)
    s = ["init", "ls /", "del longfi~1.txt", "mv longfi~2.txt short.txt", "ls /",
         "open 0 new.txt wc", "close 0", "ls /"]
    model = Model()
    model.files["LONGFI~1.TXT"] = bytearray()
    model.files["LONGFI~2.TXT"] = bytearray()
    return check_run("long names", img, s, model, real=args.real, cardtype=args.cardtype)


def full(args):
    # a small, nearly full card: writing runs out of space cleanly
    img = fatfs.mkfs(sectors=100, spc=1)
    s = ["init", "open 0 a.dat wc"] + ["write 0 2000 1"] * 20 + ["close 0", "free",
         "open 0 a.dat r", "read 0 50", "close 0", "del a.dat", "free"]
    out, steps, _ = run_script(img, s, real=args.real, cardtype=args.cardtype)
    vol = fatfs.Volume(img)
    problems = vol.check()
    full_hit = any(o.startswith("4 ") for o in out)
    ok = full_hit and not problems and out[-1] == f"0 {vol.free()}"
    for p in problems:
        print("  full: image:", p)
    print(f"{'ok  ' if ok else 'FAIL'} card full  {out[2:24]} free after: {out[-1]}")
    return ok


def randomised(args):
    rng = random.Random(args.seed)
    img = fatfs.mkfs(spc=args.spc)
    model = Model()
    names = ["a.txt", "b.dat", "c", "d.x", "longname.bin", "e1"]
    dirs = ["", "p", "q", "p/r"]
    ok = True
    for batch in range(args.batches):
        s = ["init"]
        while len(s) < args.ops:
            d = rng.choice(dirs)
            path = (d + "/" if d else "") + rng.choice(names + ["p", "q", "r"])
            free = [h for h in range(4) if h not in model.handles]
            openpaths = {hd[0] for hd in model.handles.values()}
            busy = any(p == path.upper() or p.startswith(path.upper() + "/")
                       for p in openpaths)
            r = rng.random()
            if r < 0.25 and free and not busy:
                mode = rng.choice(["wc", "rwc", "r", "wa", "rwct", "wcx", "rw"])
                c = f"open {free[0]} {path} {mode}"
            elif r < 0.45 and model.handles:
                h = rng.choice(list(model.handles))
                c = f"write {h} {rng.choice([1, 10, 100, 511, 512, 513, 1500])} {rng.randrange(256)}"
            elif r < 0.55 and model.handles:
                h = rng.choice(list(model.handles))
                c = f"read {h} {rng.choice([1, 33, 512, 1000, 2048])}"
            elif r < 0.6 and model.handles:
                h = rng.choice(list(model.handles))
                c = f"seek {h} {rng.randrange(len(model.files[model.handles[h][0]]) + 2)}"
            elif r < 0.7 and model.handles:
                c = f"close {rng.choice(list(model.handles))}"
            elif r < 0.75 and not busy:
                c = f"del {path}"
            elif r < 0.8 and not busy:
                c = f"mkdir {path}"
            elif r < 0.84 and not busy:
                c = f"rmdir {path}"
            elif r < 0.9 and not openpaths:
                d2 = rng.choice(dirs)
                c = f"mv {path} {(d2 + '/' if d2 else '') + rng.choice(names + ['p', 'q'])}"
            elif r < 0.95:
                c = f"ls {d or '/'}"
            else:
                c = f"stat {path}"
            s.append(c)
            model_copy = None  # noqa: F841
            # keep the model's handles in step as the script is built
            res = model.cmd(c)
            s[-1] = (c, res)
        s.extend((f"close {h}", model.cmd(f"close {h}")) for h in list(model.handles))
        s.append(("free", None))
        script = [c if isinstance(c, str) else c[0] for c in s]
        expect = ["0" if isinstance(c, str) else c[1] for c in s]
        ok &= check_run(f"random batch {batch}", img, script, model, real=args.real,
                        cardtype=args.cardtype, expect=expect)
        if not ok:
            break
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", action="store_true", help="bit-banged SPI to the emulated card")
    ap.add_argument("--cardtype", default="sdhc")
    ap.add_argument("--spc", type=int, default=1, help="sectors per cluster")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--ops", type=int, default=60)
    ap.add_argument("--batches", type=int, default=5)
    ap.add_argument("tests", nargs="*")
    args = ap.parse_args()
    tests = dict(basic=basic, growth=growth, bigfile=bigfile, multi=multi,
                 longnames=longnames, full=full, random=randomised)
    names = args.tests or list(tests)
    ok = all([tests[n](args) for n in names])
    print("all passed" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
