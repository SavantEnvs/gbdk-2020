/*
 * stage_input_main.c — input-staging front end for the gbdk-support CLI tools (AFL file-input targets).
 *
 * Usage:  <tool>-staged <ext> <input> <tool args...>
 *   Every tool arg equal to the literal token "@IN" is replaced by the staged copy of <input>.
 *   e.g.  ihxcheck-staged .ihx @@ @IN
 *         makebin-staged  .noi @@ -Z -yS @IN out.gb
 *
 * Why: these tools dispatch on, or derive sibling file names from, the input's file name extension
 * (ihxcheck only parses `*.ihx`, romusage picks its parser by extension, makebin -yS / makecom derive
 * `.sym` / `.noi` names from it). Mayhem's AFL runs ignored the Mayhemfile `filepath: input.<ext>`
 * (run edges equal exactly what the tools reach on a suffix-less path: ihxcheck 6, romusage 44), so
 * every input stopped at "Incompatible file extension". This front end copies the input byte-for-byte
 * to `<scratch>/input<ext>` (scratch = a fresh mkdtemp() dir under $TMPDIR, default /tmp), chdir()s
 * into it so the tool's own relative outputs (out.gb, input.sym, ./input.rel, out.com) land there,
 * and calls the tool's unmodified main() (compiled with -Dmain=staged_tool_main). The scratch dir is
 * removed by an atexit() handler, so no state survives from one input to the next.
 */
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int staged_tool_main(int argc, char **argv);

static char scratch_dir[4096];

static void remove_scratch(void) {
    if (!scratch_dir[0]) return;
    if (chdir("/") != 0) { /* keep going: paths below are absolute */ }
    DIR *d = opendir(scratch_dir);
    if (d) {
        struct dirent *e;
        char p[8192];
        while ((e = readdir(d)) != NULL) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            snprintf(p, sizeof p, "%s/%s", scratch_dir, e->d_name);
            unlink(p);
        }
        closedir(d);
    }
    rmdir(scratch_dir);
    scratch_dir[0] = '\0';
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <ext> <input> <tool args with @IN>...\n", argv[0]);
        return 2;
    }
    const char *ext = argv[1], *input = argv[2];

    FILE *in = fopen(input, "rb");
    if (!in) { perror(input); return 2; }

    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(scratch_dir, sizeof scratch_dir, "%s/gbdk-stage-XXXXXX", tmp);
    if (!mkdtemp(scratch_dir)) { perror("mkdtemp"); scratch_dir[0] = '\0'; fclose(in); return 2; }
    atexit(remove_scratch);

    char staged[4200];
    snprintf(staged, sizeof staged, "%s/input%s", scratch_dir, ext);
    FILE *out = fopen(staged, "wb");
    if (!out) { perror(staged); fclose(in); return 2; }
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { perror(staged); fclose(in); fclose(out); return 2; }
    }
    fclose(in);
    if (fclose(out) != 0) { perror(staged); return 2; }
    if (chdir(scratch_dir) != 0) { perror(scratch_dir); return 2; }

    /* tool argv: argv[0], then argv[3..] with "@IN" -> "input<ext>" (relative to the scratch cwd). */
    char staged_rel[256];
    snprintf(staged_rel, sizeof staged_rel, "input%s", ext);
    char **targv = calloc((size_t)argc - 1, sizeof *targv);
    if (!targv) return 2;
    int targc = 0;
    targv[targc++] = argv[0];
    for (int i = 3; i < argc; i++)
        targv[targc++] = strcmp(argv[i], "@IN") == 0 ? staged_rel : argv[i];
    targv[targc] = NULL;

    int rc = staged_tool_main(targc, targv);
    free(targv);
    return rc;
}
