#include "display.h"

#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

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
	IOMobileFramebufferReturn r = IOMobileFramebufferGetMainDisplay(pointer);
	if (r != 0) {
		r = IOMobileFramebufferGetSecondaryDisplay(pointer);
	}
	return r;
}

int display_init_internal(bool useDCPFlags)
{
	if (gDisplay.inited) return 0;

	int r = find_target_display(&gDisplay.display);
	if (r) return r;

	IOMobileFramebufferGetDisplaySize(gDisplay.display, &gDisplay.size);

	NSDictionary *properties = @{
		(__bridge id)kIOSurfaceWidth : @(gDisplay.size.width),
		(__bridge id)kIOSurfaceHeight : @(gDisplay.size.height),
		(__bridge id)kIOSurfacePixelFormat : @0x42475241, // 'ARGB'
		(__bridge id)kIOSurfaceBytesPerElement : @4,
		(__bridge id)kIOSurfaceCacheMode : @(
			useDCPFlags ? kIOMapWriteCombineCache | kIOMapInhibitCache | kIOMapWriteThruCache | kIOMapCopybackCache 
						: kIOMapWriteCombineCache),
	};

	gDisplay.surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
	if (!gDisplay.surface) return -1;

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

int draw_jp2_to_buf(const char* jp2_path, IOMobileFramebufferDisplaySize size, uint32_t bytesPerRow, void **bufOut, size_t *bufSizeOut)
{
	int retval = -1;
	CFURLRef imageURL = NULL;
	CGImageSourceRef cgImageSource = NULL;
	CGImageRef cgImage = NULL;
	CGContextRef context = NULL;
	CFStringRef bootImageCfString = NULL;
	CGColorSpaceRef rgbColorSpace = NULL;
	char *tmpBuf = NULL;

	bootImageCfString = CFStringCreateWithCString(kCFAllocatorDefault, jp2_path, kCFStringEncodingUTF8);
	if (!bootImageCfString) goto finish;

	imageURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, bootImageCfString, kCFURLPOSIXPathStyle, false);
	if (!imageURL) goto finish;
	cgImageSource = CGImageSourceCreateWithURL(imageURL, NULL);
	if (!cgImageSource) goto finish;
	cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, 0, NULL);
	if (!cgImage) goto finish;
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
	if (bootImageCfString) CFRelease(bootImageCfString);
	if (context) CGContextRelease(context);
	if (cgImage) CGImageRelease(cgImage);
	if (cgImageSource) CFRelease(cgImageSource);
	if (imageURL) CFRelease(imageURL);
	if (rgbColorSpace) CGColorSpaceRelease(rgbColorSpace);
	if (tmpBuf) free(tmpBuf);

	return retval;
}

int display_draw_raw(void *rawBuf, size_t rawBufSize)
{
	memcpy(gDisplay.base, rawBuf, rawBufSize);
	return display_update();
}

int display_draw_jp2(const char* jp2_path)
{
	int retval = -1;

	retval = display_init();
	if (retval) return retval;
	//display_reset();

	void *buf = NULL;
	size_t bufSize = 0;
	retval = draw_jp2_to_buf(jp2_path, gDisplay.size, gDisplay.bytesPerRow, &buf, &bufSize);
	if (retval) return retval;

	retval = display_draw_raw(buf, bufSize);
    free(buf);
	return retval;
}