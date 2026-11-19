/*
 * One-shot Metal.framework discovery probe for ios-pipa.
 *
 * Launched from configd after the system has settled. This deliberately asks
 * Metal.framework for only its system device: it distinguishes "the OS never
 * loads SweetMetal2" from a failure while opening the kernel GPU client,
 * without submitting work or changing the display's renderer.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_LIMIT (64 * 1024)

static void
dump_file(const char *path)
{
	struct stat st;
	char buf[512];
	int fd = open(path, O_RDONLY);

	if (fd < 0) {
		printf("PIPA_MTL2PROBE_FILE_OPEN_FAILED %s\n", path);
		return;
	}
	off_t start = 0;
	if (fstat(fd, &st) == 0 && st.st_size > LOG_LIMIT) {
		start = st.st_size - LOG_LIMIT;
		if (lseek(fd, start, SEEK_SET) >= 0)
			printf("PIPA_MTL2PROBE_TRUNCATED %s offset=%lld\n", path, (long long)start);
	}
	printf("PIPA_MTL2PROBE_FILE_BEGIN %s\n", path);
	ssize_t n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		(void)fwrite(buf, 1, (size_t)n, stdout);
	printf("\nPIPA_MTL2PROBE_FILE_END %s\n", path);
	close(fd);
}

int
main(int argc, char **argv)
{
	(void)argc;
	int result = 0;

	@autoreleasepool {
		const char *program = getprogname();
		printf("PIPA_MTL2PROBE_BEGIN pid=%d argv0=%s progname=%s\n", getpid(),
		    argv[0] ? argv[0] : "?", program ? program : "?");
		fflush(stdout);

		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device != nil) {
			const char *name = [[device name] UTF8String];
			printf("PIPA_MTL2PROBE_DEVICE name=%s\n", name ? name : "?");
		} else {
			printf("PIPA_MTL2PROBE_DEVICE nil\n");
			result = 2;
		}
		fflush(stdout);

		/* The plugin logs synchronously; let its final device line reach disk. */
		sleep(1);
		dump_file("/var/local/mtl2.log");
		dump_file("/var/local/m2v-cache/pipa-mtl2probe/pipelines.log");
		dump_file("/var/local/m2v-cache/backboardd/pipelines.log");
		printf("PIPA_MTL2PROBE_END result=%d\n", result);
		fflush(stdout);
	}
	return result;
}
