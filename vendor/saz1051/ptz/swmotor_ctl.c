/*
 * swmotor_ctl — userspace control for the SAZ1051 PTZ motor (MiXic MX2208A).
 *
 * Drives /dev/swmotor (misc device from motor_mx2208a.ko) via ioctl.
 * The kernel driver is a *stripped* vendor binary; its ioctl cmd->action
 * mapping cannot be recovered statically with certainty, and the factory
 * swapp's translation is likewise not byte-verified here. What IS known:
 *   * the driver accepts ioctl cmd in {0, 3, 4, 5, 6, 7, 8}
 *   * cmd 0 = reset / stop running state (verified: the tbh jump table's
 *     cmd0 handler is the stop/reset branch)
 *   * cmd 1, 2 are rejected ("not support cmd")
 *   * cmd 3,4,5,6,7,8 are movement/step variants
 * The name->cmd mapping below is therefore a HYPOTHESIS, overridden at runtime
 * by /etc/swmotor.map (lines: "<name> <cmd>"). Confirm against real motion
 * with `swmotor_ctl raw <cmd> [arg]` and edit the map accordingly. See
 * vendor/saz1051/ptz/README.md for the on-device probe procedure.
 *
 * Build: $(TARGET_CC) -o swmotor_ctl swmotor_ctl.c   (links libc normally)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define DEV      "/dev/swmotor"
#define MAPFILE  "/etc/swmotor.map"

/* default hypothesis mapping (cmd numbers are the driver's ioctl cmd) */
struct mapent {
	const char *name;
	int        cmd;
} g_map[] = {
	{ "left",  3 },
	{ "right", 4 },
	{ "up",    5 },
	{ "down",  6 },
	{ "stop",  0 },
	{ "reset", 0 },
	{ NULL,    0 }
};

static void load_map(void)
{
	FILE *f = fopen(MAPFILE, "r");
	char line[64];
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		char name[32];
		int cmd;
		if (sscanf(line, "%31s %d", name, &cmd) == 2) {
			int i;
			for (i = 0; g_map[i].name; i++) {
				if (strcmp(g_map[i].name, name) == 0) {
					g_map[i].cmd = cmd;
					break;
				}
			}
		}
	}
	fclose(f);
}

static int lookup(const char *name)
{
	int i;
	for (i = 0; g_map[i].name; i++)
		if (strcmp(g_map[i].name, name) == 0)
			return g_map[i].cmd;
	return -1;
}

static int send_cmd(int cmd, int arg)
{
	int fd = open(DEV, O_RDWR);
	int rc;
	if (fd < 0) {
		fprintf(stderr, "swmotor_ctl: cannot open %s: %m\n", DEV);
		return 2;
	}
	rc = ioctl(fd, cmd, &arg);
	if (rc < 0)
		fprintf(stderr, "swmotor_ctl: ioctl(cmd=%d,arg=%d) failed: %m\n",
			cmd, arg);
	close(fd);
	return rc < 0 ? 1 : 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage:\n"
		"  swmotor_ctl <left|right|up|down|stop|reset> [arg]\n"
		"  swmotor_ctl raw <cmd> [arg]     (send a raw ioctl cmd number)\n"
		"  swmotor_ctl map                 (print current name->cmd map)\n"
		"\n"
		"  /dev/swmotor must exist (S45saz_motor loads the driver).\n"
		"  Override name->cmd in " MAPFILE " (one '<name> <cmd>' per line).\n");
}

int main(int argc, char **argv)
{
	int cmd, arg = 0;

	if (argc < 2) {
		usage();
		return 3;
	}
	load_map();

	if (strcmp(argv[1], "map") == 0) {
		int i;
		for (i = 0; g_map[i].name; i++)
			printf("%-7s -> cmd %d\n", g_map[i].name, g_map[i].cmd);
		return 0;
	}

	if (strcmp(argv[1], "raw") == 0) {
		if (argc < 3) {
			usage();
			return 3;
		}
		cmd = atoi(argv[2]);
		if (argc > 3)
			arg = atoi(argv[3]);
		return send_cmd(cmd, arg);
	}

	cmd = lookup(argv[1]);
	if (cmd < 0) {
		fprintf(stderr, "swmotor_ctl: unknown action '%s'\n", argv[1]);
		usage();
		return 3;
	}
	if (argc > 2)
		arg = atoi(argv[2]);
	return send_cmd(cmd, arg);
}
