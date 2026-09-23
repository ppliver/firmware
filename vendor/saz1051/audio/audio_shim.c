/* audio_shim.c — LD_PRELOAD 垫片：替 majestic 补齐 SDK 要求的音频子系统初始化。
 *
 * 背景（2026-09-23 取证）：
 *   Hi3516CV610 SDK V1.0.2.1 的 sample_audio.c 在 main() 里，正式使用 AI/AO/ADEC
 *   之前必须先做 7 步初始化：
 *       ss_mpi_audio_init();
 *       ss_mpi_aenc_aac_init();  ss_mpi_adec_aac_init();
 *       ss_mpi_aenc_mp3_init();  ss_mpi_adec_mp3_init();
 *       ss_mpi_aenc_opus_init(); ss_mpi_adec_opus_init();
 *   后 6 个在 libss_mpi_audio_adp.so 里，负责把 AAC/MP3/OPUS 编解码器注册进
 *   MPP（内部走 ot_mpi_adec_register_decoder）。
 *
 *   闭源 majestic 从不调用其中任何一个（其 .dynsym 里没有任何 ss_mpi_audio_*
 *   符号），于是：
 *       ss_mpi_ai_set_pub_attr(0, ..) -> ERR_AI_NOT_CONFIG
 *       ss_mpi_adec_create_chn(0, ..) -> ERR_ADEC_NOT_CONFIG
 *                                        "decoder may not be registered"
 *   喇叭（以及麦克风、对讲）因此全程不可用。
 *
 * 为什么用 dlopen 而不是直接引用符号（2026-09-23 实测教训）：
 *   第一版把 7 个函数声明成 weak extern，构造函数里全部读到 0 —— 尽管这 7 个
 *   符号在库里是 GLOBAL FUNC，且 libss_mpi_audio.so / libss_mpi_audio_adp.so
 *   都在 majestic 的 DT_NEEDED 里。即：预加载对象在本机 musl 上解析不到主程序
 *   依赖库的符号（作用域问题）。改成 dlopen(SO, RTLD_NOW|RTLD_GLOBAL) + dlsym
 *   就稳定了（实测 7/7 rc=0，majestic 音频报错全部消失，POST /play_audio 返回
 *   200 且 /proc/umap/ao 的 chn read/write 开始增长）。
 *   dlopen 按 soname 查，musl 会用 dev/ino 去重，拿到同一个已加载实例。
 *
 * 进程门禁（v5）：
 *   LD_PRELOAD 会被 majestic 派生的所有子进程继承（sh / 脚本 / 辅助调用），
 *   那些进程里 dlopen 必失败并刷一堆噪声日志。因此先读 /proc/self/cmdline，
 *   只有确实是 majestic 自己才继续；其余进程静默返回，代价是两次 syscall。
 *
 * 日志策略：
 *   默认安静：只在 /tmp/majaudio.log 追加一行摘要
 *       [majaudio] v5 pid=NNN 7/7 ok
 *   任一步骤失败时自动打详细逐行；
 *   touch /tmp/majaudio.verbose 可强制逐行（含 dlopen 句柄）。
 *   stderr 在 start-stop-daemon -b 下会进 /dev/null，所以必须自己落盘。
 *
 * 构建（libc 无关，musl 设备可直接加载；不产生任何 DT_NEEDED）：
 *   arm-linux-gnueabihf-gcc -shared -nostdlib -fPIC -fno-stack-protector -fno-builtin \
 *       -fno-unwind-tables -fno-asynchronous-unwind-tables \
 *       -march=armv7-a -marm -o libmajaudio.so audio_shim.c
 */

#define VER_TAG "v5"

#define SO_AUDIO "libss_mpi_audio.so"
#define SO_ADP   "libss_mpi_audio_adp.so"
#define RTLD_LAZY   1
#define RTLD_NOW    2
#define RTLD_GLOBAL 0x100

#define LOG_PATH     "/tmp/majaudio.log"
#define VERBOSE_PATH "/tmp/majaudio.verbose"
#define CMDLINE_PATH "/proc/self/cmdline"
#define CMDLINE_MARK "majestic"

/* dlopen/dlsym 由 musl 的 ld.so 自己导出；这里仍用 weak，缺了也不会阻止加载。 */
extern void *dlopen(const char *name, int flag) __attribute__((weak));
extern void *dlsym(void *handle, const char *name) __attribute__((weak));

/* ARM EABI 会给 .ARM.exidx 引用 libgcc 的这几个符号；-nostdlib 下拿不到，补空实现。 */
void __aeabi_unwind_cpp_pr0(void) { }
void __aeabi_unwind_cpp_pr1(void) { }
void __aeabi_unwind_cpp_pr2(void) { }

/* ---- 极简 syscall：完全不依赖 libc ------------------------------------ */
static long sys3(long nr, long a, long b, long c)
{
    register long r7 __asm__("r7") = nr;
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    __asm__ __volatile__("svc 0"
                         : "+r"(r0)
                         : "r"(r7), "r"(r1), "r"(r2)
                         : "memory", "cc");
    return r0;
}

#define NR_WRITE  4
#define NR_OPEN   5
#define NR_CLOSE  6
#define NR_READ   3
#define NR_GETPID 20

#define O_WRONLY 0x1
#define O_CREAT  0x40
#define O_APPEND 0x400
#define O_RDONLY 0x0

static int g_log_fd = -1;
static int g_verbose;

static unsigned str_len(const char *s)
{
    unsigned n = 0;
    while (s[n]) {
        n++;
    }
    return n;
}

/* 同时写 stderr 与日志文件 */
static void emit(const char *s)
{
    unsigned n = str_len(s);
    if (n == 0) {
        return;
    }
    sys3(NR_WRITE, 2, (long)s, n);
    if (g_log_fd >= 0) {
        sys3(NR_WRITE, g_log_fd, (long)s, n);
    }
}

static const char g_hexd[] = "0123456789abcdef";

static void emit_hex(unsigned long v, int digits)
{
    char b[10];
    int i;
    if (digits > 8) {
        digits = 8;
    }
    for (i = 0; i < digits; i++) {
        b[i] = g_hexd[(v >> (4 * (digits - 1 - i))) & 0xf];
    }
    b[digits] = 0;
    emit(b);
}

static void emit_dec(long v)
{
    char b[13];
    int i = 13;
    unsigned long u = (v < 0) ? (unsigned long)(-v) : (unsigned long)v;
    b[--i] = 0;
    do {
        b[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u);
    if (v < 0) {
        b[--i] = '-';
    }
    emit(b + i);
}

static int file_exists(const char *p)
{
    long fd = sys3(NR_OPEN, (long)p, O_RDONLY, 0);
    if (fd < 0) {
        return 0;
    }
    sys3(NR_CLOSE, fd, 0, 0);
    return 1;
}

/* 读 /proc/self/cmdline 判断本进程是不是 majestic（及其 argv 变体） */
static int is_majestic(void)
{
    static char buf[256];
    long fd, n;
    unsigned i, mark = sizeof(CMDLINE_MARK) - 1;

    fd = sys3(NR_OPEN, (long)CMDLINE_PATH, O_RDONLY, 0);
    if (fd < 0) {
        return 1;                    /* 读不到就别拦，宁可多打日志 */
    }
    n = sys3(NR_READ, fd, (long)buf, sizeof(buf) - 1);
    sys3(NR_CLOSE, fd, 0, 0);
    if (n <= 0) {
        return 1;
    }
    buf[n] = 0;
    for (i = 0; i + mark <= (unsigned)n; i++) {
        unsigned j = 0;
        while (j < mark && buf[i + j] == CMDLINE_MARK[j]) {
            j++;
        }
        if (j == mark) {
            return 1;
        }
    }
    return 0;
}

/* ---- 待补的 7 步 ------------------------------------------------------ */
typedef int (*init_fn)(void);

struct step {
    const char *name;
    int         is_adp;      /* 1 = 在 libss_mpi_audio_adp.so 里 */
};

static struct step g_steps[] = {
    { "ss_mpi_audio_init",     0 },
    { "ss_mpi_aenc_aac_init",  1 },
    { "ss_mpi_adec_aac_init",  1 },
    { "ss_mpi_aenc_mp3_init",  1 },
    { "ss_mpi_adec_mp3_init",  1 },
    { "ss_mpi_aenc_opus_init", 1 },
    { "ss_mpi_adec_opus_init", 1 },
};

static int g_audio_inited;

__attribute__((constructor))
static void majaudio_init(void)
{
    void *h_audio = 0, *h_adp = 0;
    unsigned n = sizeof(g_steps) / sizeof(g_steps[0]);
    unsigned i, ok = 0, bad = 0;

    if (g_audio_inited) {
        return;
    }
    g_audio_inited = 1;

    if (dlopen == 0 || dlsym == 0 || !is_majestic()) {
        return;                      /* 非目标进程：静默退出，不做任何 I/O */
    }

    g_log_fd = (int)sys3(NR_OPEN, (long)LOG_PATH,
                         O_WRONLY | O_CREAT | O_APPEND, 0644);
    g_verbose = file_exists(VERBOSE_PATH);

    h_audio = dlopen(SO_AUDIO, RTLD_NOW | RTLD_GLOBAL);
    if (h_audio == 0) {
        h_audio = dlopen("/usr/lib/" SO_AUDIO, RTLD_NOW | RTLD_GLOBAL);
    }
    h_adp = dlopen(SO_ADP, RTLD_NOW | RTLD_GLOBAL);
    if (h_adp == 0) {
        h_adp = dlopen("/usr/lib/" SO_ADP, RTLD_NOW | RTLD_GLOBAL);
    }

    if (g_verbose) {
        emit("[majaudio] " VER_TAG " begin pid=");
        emit_dec(sys3(NR_GETPID, 0, 0, 0));
        emit(" h_audio=0x");
        emit_hex((unsigned long)h_audio, 8);
        emit(" h_adp=0x");
        emit_hex((unsigned long)h_adp, 8);
        emit("\n");
    }

    for (i = 0; i < n; i++) {
        struct step *s = &g_steps[i];
        void *h = s->is_adp ? h_adp : h_audio;
        init_fn fn = 0;
        int rc = -1;

        if (h) {
            fn = (init_fn)dlsym(h, s->name);
        }
        if (fn) {
            rc = fn();
        }

        if (fn && rc == 0) {
            ok++;
        } else {
            bad++;
            emit("[majaudio] " VER_TAG " FAIL ");
            emit(s->name);
            emit(" p=0x");
            emit_hex((unsigned long)fn, 8);
            if (fn) {
                emit(" rc=0x");
                emit_hex((unsigned long)(long)rc, 8);
            } else {
                emit(" (dlsym miss)");
            }
            emit("\n");
        }

        if (g_verbose) {
            emit("[majaudio]   ");
            emit(s->name);
            emit(" p=0x");
            emit_hex((unsigned long)fn, 8);
            if (fn) {
                emit(" rc=0x");
                emit_hex((unsigned long)(long)rc, 8);
            }
            emit("\n");
        }
    }

    emit("[majaudio] " VER_TAG " pid=");
    emit_dec(sys3(NR_GETPID, 0, 0, 0));
    emit(" ");
    emit_dec(ok);
    emit("/");
    emit_dec(n);
    emit(bad ? " FAIL\n" : " ok\n");

    if (g_log_fd >= 0) {
        sys3(NR_CLOSE, g_log_fd, 0, 0);
        g_log_fd = -1;
    }
}
