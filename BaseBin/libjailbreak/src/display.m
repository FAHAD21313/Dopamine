#include "display.h"

#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <dlfcn.h>

struct display {
	bool inited;
	void *base;
	IOMobileFramebufferDisplaySize size;
	int bytesPerRow;
	IOMobileFramebufferRef display;
	IOSurfaceRef surface;
} gDisplay;

int display_update(void)
{
	if (!gDisplay.display) return -1;

	int token;
	IOMobileFramebufferSwapBegin(gDisplay.display, &token);
	IOMobileFramebufferSwapSetLayer(gDisplay.display, 0, gDisplay.surface, (CGRect){ { 0, 0 }, { gDisplay.size.width, gDisplay.size.height } }, (CGRect){ { 0, 0 }, { gDisplay.size.width, gDisplay.size.height } }, 0);
	return IOMobileFramebufferSwapEnd(gDisplay.display);
}

IOMobileFramebufferReturn find_target_display(IOMobileFramebufferRef *pointer)
{
	if (!pointer) return -1;

	IOMobileFramebufferReturn r = IOMobileFramebufferGetMainDisplay(pointer);
	if (r != 0) {
		r = IOMobileFramebufferGetSecondaryDisplay(pointer);
	}

	return r;
}

CGSize find_display_size(void)
{
	CGSize displaySize = CGSizeMake(0,0);

	IOMobileFramebufferRef targetDisplay;
	IOMobileFramebufferReturn r = find_target_display(&targetDisplay);
	if (r == 0) {
		IOMobileFramebufferGetDisplaySize(targetDisplay, &displaySize);
	}
	else {
		// If we aren't entitled to get the display info from IOMobileFramebuffer, get it from GraphicsServices instead
		static CGSize (*__GSMainScreenPixelSize)(void) = NULL;
		if (!__GSMainScreenPixelSize) {
			void *graphicsServiceHandle = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_NOW);
			__GSMainScreenPixelSize = dlsym(graphicsServiceHandle, "GSMainScreenPixelSize");
		}

		if (__GSMainScreenPixelSize) {
			displaySize = __GSMainScreenPixelSize();
		}
	}

	return displaySize;
}

IOSurfaceRef create_iosurface_for_display(IOMobileFramebufferDisplaySize size, uint32_t cacheMode)
{
	size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 4 * size.width);

	NSDictionary *properties = @{
		(__bridge id)kIOSurfaceWidth : @(size.width),
		(__bridge id)kIOSurfaceHeight : @(size.height),
		(__bridge id)kIOSurfacePixelFormat : @0x42475241, // 'ARGB'
		(__bridge id)kIOSurfaceBytesPerRow : @(bytesPerRow),
		(__bridge id)kIOSurfaceCacheMode : @(cacheMode),
	};

	return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

int display_init_internal(bool useDCPFlags)
{
	if (gDisplay.inited) return 0;

	int r = find_target_display(&gDisplay.display);
	if (r) return r;
	gDisplay.size = find_display_size();

	gDisplay.surface = create_iosurface_for_display(gDisplay.size, useDCPFlags ? kIOMapWriteCombineCache | kIOMapInhibitCache | kIOMapWriteThruCache | kIOMapCopybackCache : kIOMapWriteCombineCache);

	IOSurfaceLock(gDisplay.surface, 0, 0);
	gDisplay.base = IOSurfaceGetBaseAddress(gDisplay.surface);
	gDisplay.bytesPerRow = IOSurfaceGetBytesPerRow(gDisplay.surface);
	IOSurfaceUnlock(gDisplay.surface, 0, 0);

	kern_return_t kr = display_update();
	if (kr == KERN_SUCCESS) {
		gDisplay.inited = true;
	}
	else {
		CFRelease(gDisplay.surface);
		if (kr == kIOReturnBadMedia) {
			return kIOReturnBadMedia;
		}
		return -1;
	}
	return 0;
}

int display_init(void)
{
	int r = display_init_internal(false);
	if (r == kIOReturnBadMedia) {
		return display_init_internal(true);
	}
	return r;
}

int display_reset(void)
{
	if (!gDisplay.base) return -1;

	memset(gDisplay.base, 0, gDisplay.size.height * gDisplay.bytesPerRow);
	display_update();
	return 0;
}

int draw_image_to_buf(CGImageRef cgImage, IOMobileFramebufferDisplaySize size, void **bufOut, size_t *bufSizeOut)
{
	size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, 4 * size.width);

	int retval = -1;
	CGContextRef context = NULL;
	CGColorSpaceRef rgbColorSpace = NULL;
	char *tmpBuf = NULL;

	rgbColorSpace = CGColorSpaceCreateDeviceRGB();
	if (!rgbColorSpace) goto finish;

	CGRect destinationRect = CGRectZero;
	CGFloat imageWidth = CGImageGetWidth(cgImage);
	CGFloat imageHeight = CGImageGetHeight(cgImage);
	
	CGFloat widthFactor = size.width / imageWidth;
	CGFloat heightFactor = size.height / imageHeight;
	CGFloat scaleFactor = widthFactor > heightFactor ? widthFactor : heightFactor;
	CGFloat scaledWidth  = imageWidth * scaleFactor;
	CGFloat scaledHeight = imageHeight * scaleFactor;

	destinationRect.size.width = scaledWidth;
	destinationRect.size.height = scaledHeight;
	
	if (widthFactor > heightFactor) {
		destinationRect.origin.y = (size.height - scaledHeight) / 2;
	} else {
		destinationRect.origin.x = (size.width - scaledWidth) / 2;
	}

	size_t bufSize = size.height * bytesPerRow;
	tmpBuf = malloc(bufSize);
	if (!tmpBuf) {
		retval = -1;
		goto finish;
	}
	memset(tmpBuf, 0, bufSize);

	context = CGBitmapContextCreate(tmpBuf, size.width, size.height, 8, bytesPerRow, rgbColorSpace, kCGImageAlphaPremultipliedFirst | kCGImageByteOrder32Little);
	if (!context) {
		retval = -1;
		goto finish;
	}

	CGContextDrawImage(context, destinationRect, cgImage);
	*bufOut = tmpBuf;
	*bufSizeOut = bufSize;
	tmpBuf = NULL;
    retval = 0;

finish:
	if (context) CGContextRelease(context);
	if (rgbColorSpace) CGColorSpaceRelease(rgbColorSpace);
	if (tmpBuf) free(tmpBuf);

	return retval;
}

int draw_image_to_buf_for_main_screen(CGImageRef image, void **bufOut, size_t *bufSizeOut)
{
	return draw_image_to_buf(image, find_display_size(), bufOut, bufSizeOut);
}

int display_draw_raw_path(const char *path)
{
	int retval = display_init();
	if (retval) return retval;

	bool worked = false;
	int fd = open(path, O_RDONLY);
	if (fd >= 0) {
		struct stat s;
		if (fstat(fd, &s) == 0) {
			size_t displayBufSize = gDisplay.size.height * gDisplay.bytesPerRow;
			if (displayBufSize == s.st_size) {
				worked = true;
				read(fd, gDisplay.base, s.st_size);
			}
		}
		close(fd);
	}

	if (!worked) return -1;

	return display_update();
}

static CGImageRef load_image(const char *image_path)
{
	CFURLRef imageURL = NULL;
	CGImageSourceRef cgImageSource = NULL;
	CGImageRef cgImage = NULL;
	CFStringRef bootImageCfString = NULL;

	bootImageCfString = CFStringCreateWithCString(kCFAllocatorDefault, image_path, kCFStringEncodingUTF8);
	if (!bootImageCfString) goto finish;
	imageURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, bootImageCfString, kCFURLPOSIXPathStyle, false);
	if (!imageURL) goto finish;
	cgImageSource = CGImageSourceCreateWithURL(imageURL, NULL);
	if (!cgImageSource) goto finish;
	cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, 0, NULL);
	if (!cgImage) goto finish;

finish:
	if (bootImageCfString) CFRelease(bootImageCfString);
	if (imageURL) CFRelease(imageURL);
	if (cgImageSource) CFRelease(cgImageSource);

	return cgImage;
}

int draw_image_path_to_buf(const char* image_path, IOMobileFramebufferDisplaySize size, void **bufOut, size_t *bufSizeOut)
{
	CGImageRef cgImage = load_image(image_path);
	if (!cgImage) return -1;
	int r = draw_image_to_buf(cgImage, size, bufOut, bufSizeOut);
	CGImageRelease(cgImage);
	return r;
}

int draw_image_path_to_buf_for_main_screen(const char* image_path, void **bufOut, size_t *bufSizeOut)
{
	CGImageRef cgImage = load_image(image_path);
	if (!cgImage) return -1;
	int r = draw_image_to_buf_for_main_screen(cgImage, bufOut, bufSizeOut);
	CGImageRelease(cgImage);
	return r;
}

int display_draw_raw(void *rawBuf, size_t rawBufSize)
{
	int retval = display_init();
	if (retval) return retval;
	size_t displayBufSize = gDisplay.size.height * gDisplay.bytesPerRow;
	if (rawBufSize != displayBufSize) {
		return -1;
	}
	memcpy(gDisplay.base, rawBuf, rawBufSize);
	return display_update();
}

int display_draw_image_path(const char* image_path)
{
	int retval = -1;

	void *buf = NULL;
	size_t bufSize = 0;
	retval = draw_image_path_to_buf_for_main_screen(image_path, &buf, &bufSize);
	if (retval) return retval;
	retval = display_draw_raw(buf, bufSize);
    free(buf);
	return retval;
}