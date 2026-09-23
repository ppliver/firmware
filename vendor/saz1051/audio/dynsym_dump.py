#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dynsym_dump.py — 转储 ELF32/64 的 .dynsym（以及 .symtab）。

用法:
  dynsym_dump.py <elf> [substr]      # 只列名字含 substr 的项；不给则全列
  dynsym_dump.py <elf> --undef       # 只列 UND（未定义/导入）
  dynsym_dump.py <elf> --def         # 只列已定义
  dynsym_dump.py <elf> --needed      # 只列 DT_NEEDED

绑定/类型用 SHN 索引原样打印，便于判断 GLOBAL/LOCAL、UND/已定义。
"""
import struct
import sys

BIND = ["LOCAL", "GLOBAL", "WEAK", "3", "4", "5", "6", "7", "8", "9",
        "10", "11", "12", "13", "14", "15"]
TYPE = ["NOTYPE", "OBJECT", "FUNC", "SECTION", "FILE", "COMMON", "TLS"]


def load(path):
    with open(path, "rb") as f:
        return f.read()


def elf_info(d):
    assert d[:4] == b"\x7fELF", "not an ELF"
    is64 = d[4] == 2
    le = d[5] == 1
    e = "<" if le else ">"
    if is64:
        (e_type, e_machine, _v, e_entry, e_phoff, e_shoff, _fl,
         _ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum,
         e_shstrndx) = struct.unpack_from(e + "HHIQQQIHHHHHH", d, 16)
    else:
        (e_type, e_machine, _v, e_entry, e_phoff, e_shoff, _fl,
         _ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum,
         e_shstrndx) = struct.unpack_from(e + "HHIIIIIHHHHHH", d, 16)
    return dict(is64=is64, e=e, e_type=e_type, e_machine=e_machine,
                e_phoff=e_phoff, e_shoff=e_shoff, e_phentsize=e_phentsize,
                e_phnum=e_phnum, e_shentsize=e_shentsize, e_shnum=e_shnum,
                e_shstrndx=e_shstrndx)


def sections(d, info):
    e, is64 = info["e"], info["is64"]
    out = []
    for i in range(info["e_shnum"]):
        off = info["e_shoff"] + i * info["e_shentsize"]
        if is64:
            name, typ, flags, addr, offset, size, link, inf, align, entsz = \
                struct.unpack_from(e + "IIQQQQIIQQ", d, off)
        else:
            name, typ, flags, addr, offset, size, link, inf, align, entsz = \
                struct.unpack_from(e + "IIIIIIIIII", d, off)
        out.append(dict(idx=i, nameoff=name, type=typ, addr=addr,
                        offset=offset, size=size, link=link, entsize=entsz))
    shstr = out[info["e_shstrndx"]]

    def sname(o):
        b = d[shstr["offset"] + o:]
        return b[:b.index(b"\x00")].decode("utf-8", "replace")

    for s in out:
        s["name"] = sname(s["nameoff"])
    return out


def segs(d, info):
    e, is64 = info["e"], info["is64"]
    out = []
    for i in range(info["e_phnum"]):
        off = info["e_phoff"] + i * info["e_phentsize"]
        if is64:
            p_type, p_flags, p_off, p_va, p_pa, p_fsz, p_msz, p_align = \
                struct.unpack_from(e + "IIQQQQQQ", d, off)
        else:
            p_type, p_off, p_va, p_pa, p_fsz, p_msz, p_flags, p_align = \
                struct.unpack_from(e + "IIIIIIII", d, off)
        out.append(dict(type=p_type, off=p_off, va=p_va, fsz=p_fsz,
                        msz=p_msz, flags=p_flags))
    return out


def va_to_off(ps, va):
    for p in ps:
        if p["va"] <= va < p["va"] + p["fsz"]:
            return p["off"] + (va - p["va"])
    return None


def read_cstr(d, off):
    b = d[off:]
    z = b.find(b"\x00")
    return b[:z if z >= 0 else len(b)].decode("utf-8", "replace")


def dump_symtab(d, info, secs, sname, want):
    e, is64 = info["e"], info["is64"]
    s = next((x for x in secs if x["name"] == sname), None)
    if s is None or s["size"] == 0:
        return None
    strtab = secs[s["link"]]
    entsz = s["entsize"] or (24 if is64 else 16)
    n = s["size"] // entsz
    rows = []
    for i in range(n):
        off = s["offset"] + i * entsz
        if is64:
            nm, inf, other, shndx, val, size = \
                struct.unpack_from(e + "IBBHQQ", d, off)
        else:
            nm, val, size, inf, other, shndx = \
                struct.unpack_from(e + "IIIBBH", d, off)
        name = read_cstr(d, strtab["offset"] + nm) if nm else ""
        bind = BIND[inf >> 4] if (inf >> 4) < len(BIND) else str(inf >> 4)
        typ = TYPE[inf & 0xf] if (inf & 0xf) < len(TYPE) else str(inf & 0xf)
        rows.append(dict(i=i, val=val, size=size, bind=bind, type=typ,
                         shndx=shndx, name=name,
                         und=(shndx == 0 and typ != "SECTION")))
        if want and want not in name:
            rows.pop()
    return rows


def _dynamic(d, info, ps):
    """产出 (tag, val) 序列。"""
    e = info["e"]
    entsz = 16 if info["is64"] else 8
    for p in ps:
        if p["type"] != 2:                      # PT_DYNAMIC
            continue
        for o in range(p["off"], p["off"] + p["fsz"], entsz):
            if info["is64"]:
                tag, val = struct.unpack_from(e + "QQ", d, o)
            else:
                tag, val = struct.unpack_from(e + "II", d, o)
            if tag == 0:
                return
            yield tag, val


def dump_needed(d, info):
    """DT_NEEDED 的 d_val 是相对 DT_STRTAB 基址的偏移（不是 vaddr）。"""
    ps = segs(d, info)
    strtab_va = None
    items = []
    for tag, val in _dynamic(d, info, ps):
        if tag == 5:                            # DT_STRTAB
            strtab_va = val
        items.append((tag, val))
    if strtab_va is None:
        return []
    stro = va_to_off(ps, strtab_va)
    if stro is None:
        return []
    out = []
    for tag, val in items:
        if tag == 1:                            # DT_NEEDED
            out.append(read_cstr(d, stro + val))
    return out


def main():
    path = sys.argv[1]
    args = sys.argv[2:]
    d = load(path)
    info = elf_info(d)
    print("#### %s (%d bytes) machine=%d %s ####"
          % (path, len(d), info["e_machine"], "ELF64" if info["is64"] else "ELF32"))

    if "--needed" in args:
        for x in dump_needed(d, info):
            print("NEEDED %s" % x)
        return

    want = None
    if "--undef" in args:
        want = None
    elif "--def" in args:
        want = None
    elif args:
        want = args[0]

    secs = sections(d, info)
    for sn in (".dynsym", ".symtab"):
        rows = dump_symtab(d, info, secs, sn, want)
        if rows is None:
            print("-- %s: absent --" % sn)
            continue
        if "--undef" in args:
            rows = [r for r in rows if r["und"]]
        if "--def" in args:
            rows = [r for r in rows if not r["und"]]
        print("-- %s: %d entries --" % (sn, len(rows)))
        for r in rows:
            print("  [%3d] %-8s %-6s shndx=%-5s val=0x%08x sz=%-6d %s"
                  % (r["i"], r["bind"], r["type"], r["shndx"], r["val"],
                     r["size"], r["name"]))


main()
