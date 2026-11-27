/*
 * File system test program for sdcard6502 (run by run.py in kim1emu).
 *
 * Reads a script of commands, one per line, from SCRIPT and writes one
 * result line per command to OUTPUT, then stops at t_done.  Each result
 * line starts with the driver's error code (0 = success).
 *
 *   init                     sd_init + fat32_init
 *   open H PATH MODE         MODE: letters r w c t a x (read, write,
 *                            create, truncate, append, exclusive)
 *   write H LEN SEED         write LEN pattern bytes -> "E written"
 *   read H LEN               -> "E count sum1 sum2"
 *   seek H POS
 *   tell H                   -> "0 pos size"
 *   close H
 *   del PATH | mkdir PATH | rmdir PATH | mv OLD NEW
 *   ls PATH                  -> "E name/size/attr ..." (all entries)
 *   stat PATH                -> "E name attr size"
 *   free                     -> "E clusters"
 *   sync
 */
#include <string.h>
#include <stdlib.h>

#define SCRIPT ((char *)0x9000)
#define OUTPUT ((char *)0x8000)

typedef unsigned char u8;
typedef unsigned int u16;
typedef unsigned long u32;

extern u8 __fastcall__ t_init(void);
extern u8 __fastcall__ t_open(void *h);
extern u8 __fastcall__ t_read(void *h);
extern u8 __fastcall__ t_write(void *h);
extern u8 __fastcall__ t_seek(void *h);
extern u8 __fastcall__ t_close(void *h);
extern u8 __fastcall__ t_delete(void);
extern u8 __fastcall__ t_rename(void);
extern u8 __fastcall__ t_mkdir(void);
extern u8 __fastcall__ t_rmdir(void);
extern u8 __fastcall__ t_opendir(void *h);
extern u8 __fastcall__ t_readdir(void *h);
extern u8 __fastcall__ t_stat(void);
extern u8 __fastcall__ t_free(void);
extern u8 __fastcall__ t_sync(void);
extern void t_done(void);
extern u8 t_mode;
extern void *t_ptr1, *t_ptr2;
extern u16 t_len;
extern u32 t_pos;

#define HSIZE 30
static u8 handles[4][HSIZE];
static u8 dirh[HSIZE];
static u8 buf[2048];
static u8 ent[32];
static char *in;
static char *out;
static char tok1[80], tok2[80], tok3[80], tok4[80];

static void put(const char *s)
{
    while (*s) *out++ = *s++;
}

static void putnum(u32 n)
{
    char tmp[12];
    u8 i = 0;
    do {
        tmp[i++] = '0' + (u8)(n % 10);
        n /= 10;
    } while (n);
    while (i) *out++ = tmp[--i];
}

static void putsp(void)
{
    *out++ = ' ';
}

static void word(char *dst)
{
    while (*in == ' ') ++in;
    while (*in && *in != ' ' && *in != '\n') *dst++ = *in++;
    *dst = 0;
}

static u8 *handle(void)
{
    return handles[atoi(tok2) & 3];
}

static char lower(u8 c)
{
    return c >= 'A' && c <= 'Z' ? c | 0x20 : c;
}

static void putname(const u8 *e)
{
    u8 i;
    for (i = 0; i < 8 && e[i] != ' '; ++i) *out++ = lower(e[i]);
    if (e[8] != ' ') {
        *out++ = '.';
        for (i = 8; i < 11 && e[i] != ' '; ++i) *out++ = lower(e[i]);
    }
}

static u32 esize(const u8 *e)
{
    return *(u32 *)(e + 28);
}

void main(void)
{
    u8 r, i;
    u16 n, s1, s2;
    u8 *h;
    in = SCRIPT;
    out = OUTPUT;
    while (*in) {
        word(tok1);
        word(tok2);
        word(tok3);
        word(tok4);
        while (*in && *in != '\n') ++in;
        if (*in) ++in;
        if (!tok1[0]) continue;
        t_ptr1 = tok2;
        t_ptr2 = tok3;
        r = 0;
        if (!strcmp(tok1, "init")) {
            r = t_init();
            putnum(r);
        } else if (!strcmp(tok1, "open")) {
            t_mode = 0;
            for (i = 0; tok4[i]; ++i) {
                switch (tok4[i]) {
                case 'r': t_mode |= 1; break;
                case 'w': t_mode |= 2; break;
                case 'c': t_mode |= 4; break;
                case 't': t_mode |= 8; break;
                case 'a': t_mode |= 16; break;
                case 'x': t_mode |= 32; break;
                }
            }
            t_ptr1 = tok3;
            putnum(t_open(handle()));
        } else if (!strcmp(tok1, "write")) {
            n = atoi(tok3);
            s1 = atoi(tok4);
            for (s2 = 0; s2 < n; ++s2)
                buf[s2] = (u8)(s1 * 31 + s2 * 7 + (s2 >> 8) * 3);
            t_ptr1 = buf;
            t_len = n;
            r = t_write(handle());
            putnum(r);
            putsp();
            putnum(t_len);
        } else if (!strcmp(tok1, "read")) {
            t_ptr1 = buf;
            t_len = atoi(tok3);
            r = t_read(handle());
            s1 = s2 = 0;
            for (n = 0; n < t_len; ++n) {
                s1 += buf[n];
                s2 += s1;
            }
            putnum(r);
            putsp();
            putnum(t_len);
            putsp();
            putnum(s1);
            putsp();
            putnum(s2);
        } else if (!strcmp(tok1, "seek")) {
            t_pos = strtoul(tok3, 0, 10);
            putnum(t_seek(handle()));
        } else if (!strcmp(tok1, "tell")) {
            h = handle();
            put("0 ");
            putnum(*(u32 *)(h + 9));
            putsp();
            putnum(*(u32 *)(h + 5));
        } else if (!strcmp(tok1, "close")) {
            putnum(t_close(handle()));
        } else if (!strcmp(tok1, "del")) {
            putnum(t_delete());
        } else if (!strcmp(tok1, "mv")) {
            putnum(t_rename());
        } else if (!strcmp(tok1, "mkdir")) {
            putnum(t_mkdir());
        } else if (!strcmp(tok1, "rmdir")) {
            putnum(t_rmdir());
        } else if (!strcmp(tok1, "ls")) {
            r = t_opendir(dirh);
            putnum(r);
            if (!r) {
                t_ptr1 = ent;
                while (!(r = t_readdir(dirh))) {
                    putsp();
                    putname(ent);
                    *out++ = '/';
                    putnum(esize(ent));
                    *out++ = '/';
                    putnum(ent[11] & 0x10 ? 1 : 0);
                }
                if (r != 0xff) {
                    put(" !");
                    putnum(r);
                }
            }
        } else if (!strcmp(tok1, "stat")) {
            t_ptr2 = ent;
            r = t_stat();
            putnum(r);
            if (!r) {
                putsp();
                putname(ent);
                putsp();
                putnum(ent[11] & 0x10 ? 1 : 0);
                putsp();
                putnum(esize(ent));
            }
        } else if (!strcmp(tok1, "free")) {
            r = t_free();
            putnum(r);
            putsp();
            putnum(t_pos);
        } else if (!strcmp(tok1, "sync")) {
            putnum(t_sync());
        } else {
            put("?");
        }
        *out++ = '\n';
    }
    *out = 0;
    t_done();
}
