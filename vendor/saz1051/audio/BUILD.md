# libmajaudio.so — the audio-init shim (SAZ1051 / Hi3516CV610)

## The problem it fixes

The vendor `majestic` binary in this tree (776496 B, md5
`0705f26452c6fd142fbc7439f166d1b5`) **never initialises the SDK audio
subsystem**. Its `.dynsym` contains no `ss_mpi_audio_*` symbol whatsoever
(dump it with `dynsym_dump.py`), and Hi3516CV610 SDK V1.0.2.1 requires seven
calls before any AI/AO/ADEC channel can be created — exactly what
`sample_comm_audio_init()` does in the SDK samples:

```c
ss_mpi_audio_init();                                     /* libss_mpi_audio.so     */
ss_mpi_aenc_aac_init();  ss_mpi_adec_aac_init();         /* libss_mpi_audio_adp.so */
ss_mpi_aenc_mp3_init();  ss_mpi_adec_mp3_init();
ss_mpi_aenc_opus_init(); ss_mpi_adec_opus_init();
```

Both libraries *are* in majestic's `DT_NEEDED` list — it just never calls the
functions. On every boot this produced:

```
[audio] AUDIO_StartAi@264: Cannot set pub attr for AiDev=0   ERR_AI_NOT_CONFIG
[play]  AUDIO_StartAdec@93: Cannot create ADEC chn 0         ERR_ADEC_NOT_CONFIG
        (ad_chn(0) decoder may not be registered)
```

With no ADEC channel bound to AO the speaker endpoint is dead:

* `GET /audio.pcm` → `HTTP/1.1 500 PCM is unavailable`
* `POST /play_audio` → accepts the body, answers 200, plays nothing

## What the shim does

A 6400-byte, libc-free `LD_PRELOAD` shared object (`audio_shim.c`) whose ELF
constructor:

1. gates on `/proc/self/cmdline` containing `majestic` — `LD_PRELOAD` is
   inherited by every helper majestic spawns, and those processes must stay
   untouched and silent;
2. `dlopen("libss_mpi_audio.so", RTLD_NOW|RTLD_GLOBAL)` and
   `dlopen("libss_mpi_audio_adp.so", RTLD_NOW|RTLD_GLOBAL)`, falling back to
   the `/usr/lib/` absolute paths;
3. `dlsym()` + calls the seven inits, then appends one summary line to
   `/tmp/majaudio.log`;
4. **configures the HiSilicon inner ACODEC** (`/dev/acodec`) — this is the
   missing half for the **microphone**. Even after the seven inits,
   `ss_mpi_ai_set_pub_attr()` still fails with `ERR_AI_NOT_CONFIG` unless the
   codec's input path is set up first. `acodec_cfg()` replays the four ioctls
   from the SDK's `sample_inner_codec_cfg_audio()` — `SOFT_RESET` →
   `SET_I2S1_FS(8k)` → `SET_MIXER_MIC(IN_D)` → `SET_INPUT_VOLUME(30)` — and
   then sets the speaker output (`SET_OUTPUT_VOLUME` + unmute both DAC
   channels) so the AO path actually emits. See the ioctl magic numbers in
   `audio_shim.c` (computed from `ot_acodec.h`, type `'A'`).

**Why `dlopen`+`dlsym` and not plain weak externs:** the first revision
declared the seven functions as `weak extern` and read **all seven as 0** —
even though they are `GLOBAL FUNC` in libraries that are already
`DT_NEEDED` by the executable. A preloaded object cannot resolve symbols out
of the main program's dependency scope on this musl toolchain. `dlopen` with
`RTLD_GLOBAL` fixes it (musl deduplicates by dev/ino, so it hands back the
already-loaded instance). Measured: 7/7 `rc=0`, and majestic's log then shows

```
[gpio] set_gpio@27: set_gpio(60, 1)
[play] init_audio_out@290: bind adec:0 to ao(0,0) ok
```

## Files

| file | purpose |
|---|---|
| `audio_shim.c` | source (version tag `v6`, raw `svc 0` syscalls only) |
| `dynsym_dump.py` | the tool used to prove the missing symbols; also dumps `DT_NEEDED` |

`libmajaudio.so` is **no longer shipped prebuilt** — it is compiled from
`audio_shim.c` by `saz1051-vendor`'s `BUILD_CMDS` (`$(TARGET_CC)`, the
OpenIPC musl cross toolchain) during the firmware build, then installed to
`/usr/lib/libmajaudio.so`. `vendor/saz1051/scripts/S95majestic` preloads it
(see the comment block inside `start()`).

## Rebuild

The `.so` is rebuilt automatically as part of the OpenIPC firmware build
(`saz1051-vendor` package → `SAZ1051_VENDOR_BUILD_CMDS`), so a normal
`make` already produces it from the current `audio_shim.c`. To rebuild it by
hand against the same toolchain:

```sh
# OpenIPC musl cross toolchain (arm-openipc-linux-musleabi-gcc), or the
# Ubuntu builder's arm-linux-gnueabihf-gcc as a fallback:
$(TARGET_CC) -shared -nostdlib -fPIC \
    -fno-stack-protector -fno-builtin \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -march=armv7-a -marm -o libmajaudio.so audio_shim.c
```

`-nostdlib` matters: the result has **no `DT_NEEDED` at all**, so it loads on
the device's musl runtime without pulling anything in, and the two
`__aeabi_unwind_cpp_pr*` stubs in the source satisfy the ARM EABI exidx
references that would otherwise need libgcc. Bump `VER_TAG` in the source and
keep the build in step with it — the log line is the only way to tell which
build is loaded (`[majaudio] v6 pid=NNN 7/7 ok` then `acodec cfg done`).

## Verified on device (2026-09-23, speaker playback path)

```
[gpio]   set_gpio(60, 1)                       -> /sys/class/gpio/gpio60 = 1
[play]   init_audio_out@290: bind adec:0 to ao(0,0) ok
/api/v1/gpio  ->  {"pin":60,"role":"speaker"}
```

Playback measured with `/proc/umap/adec` + `/proc/umap/ao` (see
`tools/spk_sampler.sh`, `tools/spk_kit.sh` in the project tree):

| pushed | `adec put_cnt` | wall time | `ao chn buf_empty` |
|---|---|---|---|
| 5 s 1 kHz tone (125 frames) | **+124** | 4–5 s (real time) | **frozen** 4–5 s |
| `/root/test.pcm` 19.2 s (480 frames) | **+480** | 18 s | **frozen** 18 s |

`buf_empty` normally advances once per 40 ms DMA frame; it stopping dead for
the whole duration of the clip means the DMA was continuously fed, i.e. the
samples genuinely left the SoC. Pushing far faster than real time overflows
the buffer and **drops** frames (250 pushed → 129 played), but does not wedge
the queue: the next single push plays normally.

### ⚠️ Not yet confirmed audible (pending real-device test on OpenIPC)
- **Speaker**: the GPIO-60 PA enable + AO/DMA path are verified at the counter
  level, and v6 now also programs the inner codec output volume + unmute. The
  actual sound pressure at the speaker still needs a human ear on OpenIPC
  (the 2026-09-23 test ran on the *vendor* firmware; the OpenIPC shim path is
  new in v6).
- **Microphone**: the `acodec_cfg()` input-path ioctls are taken verbatim from
  the SDK sample that the vendor firmware uses, so `ERR_AI_NOT_CONFIG` should
  clear — but bidirectionat capture / `GET /audio.pcm` has not been exercised
  on OpenIPC yet. Verify with `GET /audio.pcm` after this build boots.

## Two traps worth remembering

1. **`/proc/asound/cards` being empty means nothing here.** This board plays
   through MPP (`/proc/umap/ao`, `/proc/umap/adec`), not ALSA; `/dev/snd` only
   ever contains `timer`. Do not conclude "audio isn't running" from it — an
   earlier note in `majestic.yaml` did exactly that and was wrong.
2. **The device's busybox `wget --post-file` is broken.** It sends
   `Content-Length: 0` and no body at all, so it looks like a successful POST
   (`rc=0`, `HTTP/1.1 200 OK`) while nothing is ever played. A whole round of
   "`/play_audio` returns 200 but the queue is stuck" conclusions came from
   that. Verify playback from the counters, never from the HTTP status — a
   POST to any non-existent path also returns 200 with an empty body.
   Device-side use `tools/spk_play.sh` (hand-built request through `nc`);
   host-side use `tools/play_audio.py`.

## Known cosmetic issue

`/tmp/majaudio.log` also carries a `[majaudio] v6 pid=N 0/7 FAIL ...` block
from one auxiliary process besides the daemon's `7/7 ok`. That process
inherits `LD_PRELOAD` and has `majestic` in its cmdline (so the gate lets it
through) but cannot `dlopen` the audio libs, and its failures are harmless —
the daemon itself reports `7/7 ok`. Tightening the gate to require the
cmdline to *begin with* `majestic` would silence it; it is left alone because
`audio_shim.c` and the built `libmajaudio.so` are currently in step.
