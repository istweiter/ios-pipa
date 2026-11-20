/*
 * Milestone 4: act as iBoot for xnu.
 *
 * mkpayload.py already resolved the kernel's chained fixups and built the
 * ADT, so this only has to: find the payload in the ABL ramdisk, copy the
 * segments to phys_base + (vmaddr - virt_base), place the ADT and
 * boot_args behind the kernel, and jump to the entry point with the MMU
 * and caches off, x0 = boot_args (physical).
 */
#include <stdint.h>
#include "console.h"
#include "fdt.h"
#include "loader.h"

#define BOOT_LINE_LENGTH	608
#define PAGE_16K		0x4000UL
#define PIPA_SPLASH_BYTES	0x2300000UL

extern char _head[], _end[];

struct payload_seg {
	uint64_t vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	uint32_t version, nsegs;
	uint64_t virt_base, entry_va, adt_off, adt_size, kernel_end;
	uint64_t phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

/* pexpert/pexpert/arm64/boot.h, Revision/Version 2 */
struct boot_video {
	uint64_t v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	uint16_t Revision, Version;
	uint64_t virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	uint32_t machineType;
	uint64_t deviceTreeP;
	uint32_t deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	uint64_t bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload header layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

/* MMU off: everything is Device memory, so copy in aligned 8-byte words. */
static void copy64(uintptr_t dst, uintptr_t src, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile const uint64_t *s = (volatile const uint64_t *)src;
	for (uint64_t i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(uintptr_t dst, uint64_t n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	for (uint64_t i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int magic_ok(const char *m)
{
	static const char want[] = "SWEETXNU";
	for (int i = 0; i < 8; i++)
		if (m[i] != want[i])
			return 0;
	return 1;
}

static int overlaps(uint64_t base, uint64_t end, uint64_t other_base, uint64_t other_end)
{
	return base < other_end && other_base < end;
}

/* The source initrd is dead after all payload segments and the ADT have been
 * copied. It was reserved by ABL and is outside XNU's managed RAM. Give its
 * first three aligned frames to the DPU only if it can address them.
 */
static uint64_t scanout_base(uintptr_t dtb, uint64_t rd_start, uint64_t rd_end, uint64_t bytes)
{
	uint32_t dtb_size = fdt_blob_size(dtb);
	if (rd_start < 0x80000000UL || rd_end > 0x100000000UL ||
	    rd_start >= rd_end || !dtb_size)
		return 0;
	uint64_t base = (rd_start + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uint64_t end = base + bytes;
	if (end > rd_end ||
	    overlaps(base, end, dtb, dtb + dtb_size) ||
	    overlaps(base, end, (uintptr_t)_head, (uintptr_t)_end) ||
	    overlaps(base, end, FB_BASE, FB_BASE + PIPA_SPLASH_BYTES))
		return 0;
	return base;
}

static int adt_string_equal(const char *data, const char *key)
{
	while (*key && *data == *key)
		data++, key++;
	return *data == *key;
}

/* mkadt.py puts /chosen first. ADT property data is only four-byte aligned. */
static uintptr_t adt_properties(uintptr_t node, uintptr_t end, uintptr_t *pool, int *is_chosen)
{
	if (node > end || end - node < 8)
		return 0;
	uint32_t count = *(const uint32_t *)node;
	uintptr_t p = node + 8;
	for (uint32_t i = 0; i < count; i++) {
		if (end - p < 36)
			return 0;
		const char *name = (const char *)p;
		uint32_t bytes = *(const uint32_t *)(p + 32) & 0x7fffffffU;
		uint64_t padded = ((uint64_t)bytes + 3) & ~3UL;
		uintptr_t value = p + 36;
		if (padded > end - value)
			return 0;
		if (pool && bytes == 16 && adt_string_equal(name, "pipa-scanout-pool"))
			*pool = value;
		if (is_chosen && bytes == 7 && adt_string_equal(name, "name") &&
		    adt_string_equal((const char *)value, "chosen"))
			*is_chosen = 1;
		p = value + padded;
	}
	return p;
}

static void adt_set_scanout_pool(uintptr_t adt, uint64_t adt_size, uintptr_t dtb,
				uint64_t rd_start, uint64_t rd_end)
{
	if (adt_size > UINTPTR_MAX - adt)
		return;
	uint64_t frame = ((uint64_t)FB_STRIDE * FB_H + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uint64_t bytes = 3 * frame;
	uint64_t base = scanout_base(dtb, rd_start, rd_end, bytes);
	if (!base)
		return;
	uintptr_t end = adt + adt_size;
	uintptr_t child = adt_properties(adt, end, 0, 0);
	uintptr_t slot = 0;
	int is_chosen = 0;
	if (!child || !adt_properties(child, end, &slot, &is_chosen) || !is_chosen || !slot)
		return;
	volatile uint32_t *range = (volatile uint32_t *)slot;
	range[0] = (uint32_t)base;
	range[1] = 0;
	range[2] = (uint32_t)bytes;
	range[3] = 0;
	con_hex2("SCANOUT", "base=", base, "size=", bytes);
}

typedef void (*xnu_entry_t)(uint64_t boot_args_pa);

const char *loader_boot(uintptr_t dtb)
{
	uint64_t rd_start, rd_end;

	if (!fdt_chosen_u64(dtb, "linux,initrd-start", &rd_start) ||
	    !fdt_chosen_u64(dtb, "linux,initrd-end", &rd_end))
		return "no initrd in /chosen";
	con_hex2("INITRD", "lo=", rd_start, "hi=", rd_end);

	const struct payload *p = (const struct payload *)rd_start;
	if (!magic_ok(p->magic))
		return "no SWEETXNU payload";
	if (p->version != 1 || (p->adt_off & 7) || (rd_start & 7))
		return "bad payload header";

	uint64_t pa_of_va_base = p->phys_base - p->virt_base;	/* pa = va + this */
	con_hex2("PHYS", "base=", p->phys_base, "size=", p->mem_size);
	con_hex("VIRT", p->virt_base);
	con_hex("ENTRY", p->entry_va);

	/* The payload must not overlap where the kernel goes. */
	if (rd_end > p->phys_base && rd_start < p->phys_base + p->mem_size)
		return "ramdisk overlaps kernel memory";

	for (uint32_t i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		uintptr_t dst = s->vmaddr + pa_of_va_base;
		copy64(dst, rd_start + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL), s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	con_hex2("SEGS", "n=", p->nsegs, "end=", p->kernel_end + pa_of_va_base);

	/* ADT, then boot_args, behind the kernel; everything below topOfKernelData is ours. */
	uintptr_t adt_pa = p->kernel_end + pa_of_va_base;
	copy64(adt_pa, rd_start + p->adt_off, p->adt_size);
	adt_set_scanout_pool(adt_pa, p->adt_size, dtb, rd_start, rd_end);
	uintptr_t ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	uintptr_t top = ba_pa + PAGE_16K;

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = FB_BASE;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = FB_STRIDE;
	ba->Video.v_width = FB_W;
	ba->Video.v_height = FB_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - pa_of_va_base;	/* xnu reads it with the MMU on: a VA */
	ba->deviceTreeLength = (uint32_t)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	con_hex2("BOOTARG", "pa=", ba_pa, "top=", top);

	uintptr_t entry_pa = p->entry_va + pa_of_va_base;
	con_hex("JUMP", entry_pa);
	con_str("XNU", "jumping (fbcon clears screen)");

	/* Everything was written with the MMU and caches off; drop any stale I-cache lines too. */
	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	return "xnu returned";
}
