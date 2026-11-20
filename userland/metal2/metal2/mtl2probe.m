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
#include <signal.h>
#include <stdint.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

#define LOG_LIMIT (64 * 1024)
#define RENDER_SIDE 64

static void
gpu_timeout(int signo)
{
	(void)signo;
	static const char message[] = "PIPA_MTL2PROBE_GPU_TIMEOUT after 30 seconds\n";
	(void)write(STDOUT_FILENO, message, sizeof(message) - 1);
	_exit(124);
}

/* Exercise the actual Metal frontend and verify pixels returned by the GPU. */
static int
render_clear_readback(id<MTLDevice> device)
{
	const NSUInteger row_bytes = RENDER_SIDE * 4;
	const NSUInteger byte_count = row_bytes * RENDER_SIDE;
	NSUInteger bad_pixels = 0;
	NSUInteger first_bad = NSNotFound;

	printf("PIPA_MTL2PROBE_RENDER_BEGIN side=%d format=BGRA8 blue-clear\n", RENDER_SIDE);
	fflush(stdout);

	id<MTLCommandQueue> queue = [device newCommandQueue];
	MTLTextureDescriptor *texture_desc = [MTLTextureDescriptor
	    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	    width:RENDER_SIDE height:RENDER_SIDE mipmapped:NO];
	texture_desc.usage = MTLTextureUsageRenderTarget;
	texture_desc.storageMode = MTLStorageModePrivate;
	id<MTLTexture> target = queue ? [device newTextureWithDescriptor:texture_desc] : nil;
	id<MTLBuffer> readback = [device newBufferWithLength:byte_count
	    options:MTLResourceStorageModeShared];
	if (!queue || !target || !readback || ![readback contents]) {
		printf("PIPA_MTL2PROBE_RENDER_SETUP_FAILED queue=%d texture=%d readback=%d\n",
		    queue != nil, target != nil, readback != nil);
		return 1;
	}

	memset([readback contents], 0, byte_count);
	id<MTLCommandBuffer> commands = [queue commandBuffer];
	if (!commands) {
		printf("PIPA_MTL2PROBE_RENDER_SETUP_FAILED commandBuffer=nil\n");
		return 1;
	}

	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = target;
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0);
	id<MTLRenderCommandEncoder> render = [commands renderCommandEncoderWithDescriptor:pass];
	if (!render) {
		printf("PIPA_MTL2PROBE_RENDER_SETUP_FAILED renderEncoder=nil\n");
		return 1;
	}
	[render endEncoding];

	id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
	if (!blit) {
		printf("PIPA_MTL2PROBE_RENDER_SETUP_FAILED blitEncoder=nil\n");
		return 1;
	}
	[blit copyFromTexture:target
	    sourceSlice:0 sourceLevel:0
	    sourceOrigin:MTLOriginMake(0, 0, 0)
	    sourceSize:MTLSizeMake(RENDER_SIDE, RENDER_SIDE, 1)
	    toBuffer:readback destinationOffset:0
	    destinationBytesPerRow:row_bytes destinationBytesPerImage:byte_count];
	[blit endEncoding];

	/* Keep a broken GPU wait from wedging the system's diagnostic runner. */
	struct sigaction action = {0};
	action.sa_handler = gpu_timeout;
	sigemptyset(&action.sa_mask);
	(void)sigaction(SIGALRM, &action, NULL);
	alarm(30);
	[commands commit];
	[commands waitUntilCompleted];
	alarm(0);

	if ([commands status] != MTLCommandBufferStatusCompleted) {
		printf("PIPA_MTL2PROBE_RENDER_COMMAND_FAILED status=%lu error=%s\n",
		    (unsigned long)[commands status], commands.error.description.UTF8String ?: "none");
		return 1;
	}

	const uint8_t *pixels = [readback contents];
	for (NSUInteger y = 0; y < RENDER_SIDE; ++y) {
		for (NSUInteger x = 0; x < RENDER_SIDE; ++x) {
			const uint8_t *pixel = pixels + y * row_bytes + x * 4;
			/* BGRA8 bytes for a solid blue clear. */
			if (pixel[0] != 0xff || pixel[1] != 0 || pixel[2] != 0 || pixel[3] != 0xff) {
				if (first_bad == NSNotFound)
					first_bad = y * RENDER_SIDE + x;
				++bad_pixels;
			}
		}
	}
	if (bad_pixels) {
		const uint8_t *pixel = pixels + first_bad * 4;
		printf("PIPA_MTL2PROBE_RENDER_FAIL bad_pixels=%lu/%u first=%lu bgra_bytes=%02x,%02x,%02x,%02x\n",
		    (unsigned long)bad_pixels, RENDER_SIDE * RENDER_SIDE, (unsigned long)first_bad,
		    pixel[0], pixel[1], pixel[2], pixel[3]);
		return 1;
	}
	printf("PIPA_MTL2PROBE_RENDER_PASS pixels=%u first=00,00,ff,ff\n", RENDER_SIDE * RENDER_SIDE);
	return 0;
}

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
		if (device != nil && render_clear_readback(device) != 0)
			result = 3;
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
