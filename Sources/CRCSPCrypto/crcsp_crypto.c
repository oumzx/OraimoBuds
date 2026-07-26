/* Minimal ELF64/aarch64 loader for Jieli's libjl_bluetooth.so, running
 * natively on Apple Silicon (same CPU arch as the Android .so, so the raw
 * machine code executes with zero translation). Loads the module
 * in-process, applies its RELATIVE/JUMP_SLOT relocations and the
 * TPIDR_EL0/W^X patches Apple Silicon needs, then drives it through a
 * JNI shim to call the vendor's real getEncryptedAuthData() — this is
 * the RCSP auth handshake's proprietary crypto step, extracted and
 * re-hosted rather than hand-ported (see project notes for why).
 */
#include "include/crcsp_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

/* ---- minimal ELF64 aarch64 structs (no elf.h on macOS) ---- */
typedef struct {
    unsigned char e_ident[16];
    uint16_t e_type, e_machine;
    uint32_t e_version;
    uint64_t e_entry, e_phoff, e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    uint32_t p_type, p_flags;
    uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
} Elf64_Phdr;

typedef struct { int64_t d_tag; uint64_t d_val; } Elf64_Dyn;

typedef struct {
    uint32_t st_name;
    unsigned char st_info, st_other;
    uint16_t st_shndx;
    uint64_t st_value, st_size;
} Elf64_Sym;

typedef struct { uint64_t r_offset, r_info; int64_t r_addend; } Elf64_Rela;

#define PT_LOAD 1
#define DT_NULL 0
#define DT_STRTAB 5
#define DT_SYMTAB 6
#define DT_RELA 7
#define DT_RELASZ 8
#define DT_JMPREL 23
#define DT_PLTRELSZ 2
#define R_AARCH64_RELATIVE 1027
#define R_AARCH64_JUMP_SLOT 1026
#define R_AARCH64_GLOB_DAT 1025
#define SHN_UNDEF 0

/* ---- native stubs for external imports the .so needs ---- */
static uint8_t g_heap[1 << 22];
static size_t g_heap_off = 0;
static void *stub_malloc(size_t n) {
    n = (n + 15) & ~((size_t)15);
    if (g_heap_off + n > sizeof(g_heap)) return NULL;
    void *p = &g_heap[g_heap_off];
    g_heap_off += n;
    return p;
}
static void stub_free(void *p) { (void)p; }
static unsigned long g_seed = 88172645463325252UL;
static int stub_rand(void) {
    g_seed ^= g_seed << 13; g_seed ^= g_seed >> 7; g_seed ^= g_seed << 17;
    return (int)(g_seed & 0x7fffffff);
}
static int stub_cxa_atexit(void *f, void *arg, void *d) { (void)f; (void)arg; (void)d; return 0; }
static void stub_cxa_finalize(void *d) { (void)d; }
static void stub_stack_chk_fail(void) { fprintf(stderr, "[CRCSPCrypto] stack check failed\n"); abort(); }
static int stub_android_log_print(int prio, const char *tag, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[jl %d/%s] ", prio, tag);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    return 0;
}

/* ---- JNI shim ---- */
typedef struct { const char *name; const char *sig; void *fnPtr; } JNINativeMethod;
typedef struct { char name[64]; void *fn; } CapturedMethod;
static CapturedMethod g_methods[32];
static int g_method_count = 0;
typedef struct { uint8_t *data; long len; } FakeArray;
typedef struct { void **functable; } EnvObj;
typedef struct { void **functable; } VmObj;
static VmObj *g_vmObj;
static EnvObj *g_envObj;

static void *my_FindClass(void *env, const char *name) { (void)env; (void)name; return (void *)0x1000; }
static void *my_NewGlobalRef(void *env, void *obj) { (void)env; return obj; }
static void *my_GetObjectClass(void *env, void *obj) { (void)env; (void)obj; return (void *)0x1000; }
static long my_GetArrayLength(void *env, void *arr) { (void)env; return ((FakeArray *)arr)->len; }
static void *my_NewByteArray(void *env, int len) {
    (void)env;
    FakeArray *a = malloc(sizeof(FakeArray));
    a->data = calloc(1, len);
    a->len = len;
    return a;
}
static void *my_GetByteArrayElements(void *env, void *arr, void *isCopy) {
    (void)env;
    if (isCopy) *(char *)isCopy = 0;
    return ((FakeArray *)arr)->data;
}
static void my_ReleaseByteArrayElements(void *env, void *arr, void *elems, int mode) {
    (void)env; (void)arr; (void)elems; (void)mode;
}
static void my_SetByteArrayRegion(void *env, void *arr, int start, int len, const void *buf) {
    (void)env;
    memcpy(((FakeArray *)arr)->data + start, buf, len);
}
static int my_RegisterNatives(void *env, void *clazz, const JNINativeMethod *methods, int nMethods) {
    (void)env; (void)clazz;
    for (int i = 0; i < nMethods && g_method_count < 32; i++) {
        strncpy(g_methods[g_method_count].name, methods[i].name, 63);
        g_methods[g_method_count].fn = methods[i].fnPtr;
        g_method_count++;
    }
    return 1;
}
static int my_GetEnv(void *vm, void **envOut, int version) { (void)vm; (void)version; *envOut = g_envObj; return 0; }
static int my_GetJavaVM(void *env, void **vmOut) { (void)env; *vmOut = g_vmObj; return 0; }

static void *find_method(const char *name) {
    for (int i = 0; i < g_method_count; i++)
        if (strcmp(g_methods[i].name, name) == 0) return g_methods[i].fn;
    return NULL;
}

/* ---- captured entry points, set by rcsp_crypto_load ---- */
typedef void *(*getEncryptedAuthData_t)(void *, void *, void *);
static getEncryptedAuthData_t g_getEncryptedAuthData = NULL;
static int g_loaded = 0;

int rcsp_crypto_load(const char *soPath) {
    if (g_loaded) return 0;

    int fd = open(soPath, O_RDONLY);
    if (fd < 0) { perror("[CRCSPCrypto] open"); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0) { perror("[CRCSPCrypto] fstat"); close(fd); return 1; }
    uint8_t *file = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (file == MAP_FAILED) { perror("[CRCSPCrypto] mmap file"); return 1; }

    Elf64_Ehdr *eh = (Elf64_Ehdr *)file;
    if (memcmp(eh->e_ident, "\x7f""ELF", 4) != 0) {
        fprintf(stderr, "[CRCSPCrypto] not an ELF file\n");
        return 1;
    }

    Elf64_Phdr *phdrs = (Elf64_Phdr *)(file + eh->e_phoff);
    uint64_t maxAddr = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            uint64_t end = phdrs[i].p_vaddr + phdrs[i].p_memsz;
            if (end > maxAddr) maxAddr = end;
        }
    }
    size_t realImageSize = (maxAddr + 0xFFF) & ~(uint64_t)0xFFF;
    uint64_t fakeTlsOff = realImageSize; /* extra RW page, landing pad for
                                            patched TPIDR_EL0 reads */
    size_t imageSize = realImageSize + 16384;

    uint8_t *base = mmap(NULL, imageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) { perror("[CRCSPCrypto] mmap image"); return 1; }
    memset(base, 0, imageSize);

    for (int i = 0; i < eh->e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;
        memcpy(base + phdrs[i].p_vaddr, file + phdrs[i].p_offset, phdrs[i].p_filesz);
    }

    /* macOS's TPIDR_EL0 doesn't hold a bionic-style TLS block, so the .so's
       stack-canary reads (`mrs xN, TPIDR_EL0; ldr x?,[xN,#0x28]`) fault.
       Patch each 4-byte `mrs xN, TPIDR_EL0` into an `adr xN, <fake TLS
       page>` of the same size — self-consistent since the entry-store and
       exit-compare both hit the same controlled memory. These 8 sites are
       specific to this build of libjl_bluetooth.so. */
    {
        struct { uint64_t vaddr; int rd; } sites[] = {
            {0x12e4, 8}, {0x1648, 23}, {0x17c8, 8}, {0x18e8, 8},
            {0x1d54, 20}, {0x1e1c, 20}, {0x1fc8, 21}, {0x2174, 22},
        };
        uint64_t targetAddr = (uint64_t)(base + fakeTlsOff);
        for (size_t i = 0; i < sizeof(sites) / sizeof(sites[0]); i++) {
            uint64_t instrAddr = (uint64_t)(base + sites[i].vaddr);
            int64_t offset = (int64_t)(targetAddr - instrAddr);
            uint32_t imm21 = (uint32_t)offset & 0x1FFFFF;
            uint32_t immlo = imm21 & 0x3;
            uint32_t immhi = (imm21 >> 2) & 0x7FFFF;
            uint32_t insn = (immlo << 29) | (0x10u << 24) | (immhi << 5) | (uint32_t)sites[i].rd;
            *(uint32_t *)(base + sites[i].vaddr) = insn;
        }
    }

    Elf64_Dyn *dyn = NULL;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (phdrs[i].p_type == 2 /* PT_DYNAMIC */) dyn = (Elf64_Dyn *)(file + phdrs[i].p_offset);
    }
    if (!dyn) { fprintf(stderr, "[CRCSPCrypto] no PT_DYNAMIC\n"); return 1; }

    uint64_t strtabOff = 0, symtabOff = 0, relaOff = 0, relaSz = 0;
    uint64_t jmprelOff = 0, pltrelSz = 0;
    for (Elf64_Dyn *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
            case DT_STRTAB: strtabOff = d->d_val; break;
            case DT_SYMTAB: symtabOff = d->d_val; break;
            case DT_RELA: relaOff = d->d_val; break;
            case DT_RELASZ: relaSz = d->d_val; break;
            case DT_JMPREL: jmprelOff = d->d_val; break;
            case DT_PLTRELSZ: pltrelSz = d->d_val; break;
        }
    }
    const char *strtab = (const char *)(file + strtabOff);
    Elf64_Sym *symtab = (Elf64_Sym *)(file + symtabOff);

    int relaCount = (int)(relaSz / sizeof(Elf64_Rela));
    Elf64_Rela *relas = (Elf64_Rela *)(file + relaOff);
    for (int i = 0; i < relaCount; i++) {
        uint32_t type = relas[i].r_info & 0xffffffff;
        if (type == R_AARCH64_RELATIVE) {
            *(uint64_t *)(base + relas[i].r_offset) = (uint64_t)base + relas[i].r_addend;
        }
    }

    int jmprelCount = (int)(pltrelSz / sizeof(Elf64_Rela));
    Elf64_Rela *jmprels = (Elf64_Rela *)(file + jmprelOff);
    for (int i = 0; i < jmprelCount; i++) {
        uint32_t type = jmprels[i].r_info & 0xffffffff;
        uint32_t symIdx = (uint32_t)(jmprels[i].r_info >> 32);
        Elf64_Sym *sym = &symtab[symIdx];
        const char *name = strtab + sym->st_name;
        void *target = NULL;

        if (strcmp(name, "malloc") == 0) target = (void *)stub_malloc;
        else if (strcmp(name, "free") == 0) target = (void *)stub_free;
        else if (strcmp(name, "rand") == 0) target = (void *)stub_rand;
        else if (strcmp(name, "__cxa_atexit") == 0) target = (void *)stub_cxa_atexit;
        else if (strcmp(name, "__cxa_finalize") == 0) target = (void *)stub_cxa_finalize;
        else if (strcmp(name, "__stack_chk_fail") == 0) target = (void *)stub_stack_chk_fail;
        else if (strcmp(name, "__android_log_print") == 0) target = (void *)stub_android_log_print;
        else if (sym->st_shndx != SHN_UNDEF) target = base + sym->st_value;
        else fprintf(stderr, "[CRCSPCrypto] unresolved import: %s\n", name);

        if (type == R_AARCH64_JUMP_SLOT || type == R_AARCH64_GLOB_DAT) {
            *(uint64_t *)(base + jmprels[i].r_offset) = (uint64_t)target;
        }
    }

    uint64_t jniOnLoadAddr = 0;
    for (int i = 0; i < 200; i++) {
        Elf64_Sym *sym = &symtab[i];
        if (sym->st_name == 0 || sym->st_name > 0x2000) continue;
        const char *name = strtab + sym->st_name;
        if (name[0] < 32 || name[0] > 126) continue;
        if (strcmp(name, "JNI_OnLoad") == 0) { jniOnLoadAddr = sym->st_value; break; }
    }
    if (!jniOnLoadAddr) jniOnLoadAddr = 0x1d44; /* known offset for this build */

    int NSLOTS = 256;
    void **envFuncs = calloc((size_t)NSLOTS, sizeof(void *));
    envFuncs[6] = (void *)my_FindClass;
    envFuncs[21] = (void *)my_NewGlobalRef;
    envFuncs[31] = (void *)my_GetObjectClass;
    envFuncs[171] = (void *)my_GetArrayLength;
    envFuncs[176] = (void *)my_NewByteArray;
    envFuncs[184] = (void *)my_GetByteArrayElements;
    envFuncs[192] = (void *)my_ReleaseByteArrayElements;
    envFuncs[208] = (void *)my_SetByteArrayRegion;
    envFuncs[215] = (void *)my_RegisterNatives;
    envFuncs[219] = (void *)my_GetJavaVM;
    EnvObj *envObj = malloc(sizeof(EnvObj));
    envObj->functable = envFuncs;
    g_envObj = envObj;

    void **vmFuncs = calloc(64, sizeof(void *));
    vmFuncs[6] = (void *)my_GetEnv;
    VmObj *vmObj = malloc(sizeof(VmObj));
    vmObj->functable = vmFuncs;
    g_vmObj = vmObj;

    /* W^X per-segment: data segments must stay writable at runtime (e.g.
       nativeInit caches a JNI global-ref pointer into .data), only the
       code segment needs to flip to executable. */
    const size_t PAGE = 16384;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;
        uint64_t start = phdrs[i].p_vaddr & ~(uint64_t)(PAGE - 1);
        uint64_t end = (phdrs[i].p_vaddr + phdrs[i].p_memsz + PAGE - 1) & ~(uint64_t)(PAGE - 1);
        int prot = PROT_READ;
        if (phdrs[i].p_flags & 0x1) prot |= PROT_EXEC;
        if (phdrs[i].p_flags & 0x2) prot |= PROT_WRITE;
        if (mprotect(base + start, end - start, prot) != 0) {
            fprintf(stderr, "[CRCSPCrypto] mprotect segment %d failed: %s\n", i, strerror(errno));
            return 1;
        }
    }

    typedef int (*JNI_OnLoad_t)(void *, void *);
    JNI_OnLoad_t JNI_OnLoad = (JNI_OnLoad_t)(base + jniOnLoadAddr);
    JNI_OnLoad(vmObj, NULL);

    typedef int (*nativeInit_t)(void *, void *);
    nativeInit_t nativeInit = (nativeInit_t)find_method("nativeInit");
    if (nativeInit) nativeInit(g_envObj, (void *)0x2000);

    g_getEncryptedAuthData = (getEncryptedAuthData_t)find_method("getEncryptedAuthData");
    if (!g_getEncryptedAuthData) {
        fprintf(stderr, "[CRCSPCrypto] getEncryptedAuthData not captured\n");
        return 1;
    }

    g_loaded = 1;
    return 0;
}

void rcsp_crypto_random_challenge(uint8_t out[17]) {
    out[0] = 0x00;
    arc4random_buf(out + 1, 16);
}

int rcsp_crypto_encrypt(const uint8_t in_[17], uint8_t out[17]) {
    if (!g_loaded || !g_getEncryptedAuthData) return 1;
    FakeArray in;
    in.data = (uint8_t *)in_;
    in.len = 17;
    FakeArray *result = (FakeArray *)g_getEncryptedAuthData(g_envObj, (void *)0x2000, &in);
    if (!result || result->len != 17) return 1;
    memcpy(out, result->data, 17);
    return 0;
}
