//
//  UIImageView+DownsizeLargeImage.m
//  LargeImageDownsizing
//
//  Created by Deep Thought on 2019/7/2.
//  Copyright © 2019 Zane. All rights reserved.
//

#import "UIImageView+DownsizeLargeImage.h"
#import <objc/runtime.h>


#define kDestImageSizeMB 120.0f // The resulting image will be (x)MB of uncompressed image data.
#define kSourceImageTileSizeMB 40.0f // The tile size will be (x)MB of uncompressed image data.
#define bytesPerMB 1048576.0f
#define bytesPerPixel 4.0f
#define pixelsPerMB ( bytesPerMB / bytesPerPixel ) // 262144 pixels, for 4 bytes per pixel.
#define destTotalPixels kDestImageSizeMB * pixelsPerMB
#define tileTotalPixels kSourceImageTileSizeMB * pixelsPerMB
#define destSeemOverlap 2.0f // the numbers of pixels to overlap the seems where tiles meet.

@interface UIImageView()

@property (nonatomic, assign) BOOL downsizing;
// the temporary container used to hold the resulting output image pixel
// data, as it is being assembled.
@property (nonatomic,assign) CGContextRef destContext;

@end

@implementation UIImageView (DownsizeLargeImage)

- (void)ybw_setImageWithFilename:(NSString *)filename {
    if (!filename || self.downsizing) {
        return;
    }
    [NSThread detachNewThreadSelector:@selector(downsize:) toTarget:self withObject:filename];
}

- (void)downsize:(NSString *)filename{
    @autoreleasepool {// create an autorelease pool to catch calls to -autorelease.
        self.downsizing = YES;
        // sub rect of the input image bounds that represents the
        // maximum amount of pixel data to load into mem at one time.
        CGRect sourceTile;
        // sub rect of the output image that is proportionate to the
        // size of the sourceTile.
        CGRect destTile;
        // the ratio of the size of the input image to the output image.
        float imageScale;
        // source image width and height
        CGSize sourceResolution;
        // total number of pixels in the source image
        float sourceTotalPixels;
        // total number of megabytes of uncompressed pixel data in the source image.
        float sourceTotalMB;
        // output image width and height
        CGSize destResolution;
        // the number of pixels to overlap tiles as they are assembled.
        float sourceSeemOverlap;
        
        // create an image from the image filename constant. Note this
        // doesn't actually read any pixel information from disk, as that
        // is actually done at draw time.
        UIImage* sourceImage = [[UIImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:filename ofType:nil]];
        
        if( sourceImage == nil ) NSLog(@"input image not found!");
        // get the width and height of the input image using
        // core graphics image helper functions.
        sourceResolution.width = CGImageGetWidth(sourceImage.CGImage);
        sourceResolution.height = CGImageGetHeight(sourceImage.CGImage);
        // use the width and height to calculate the total number of pixels
        // in the input image.
        sourceTotalPixels = sourceResolution.width * sourceResolution.height;
        // calculate the number of MB that would be required to store
        // this image uncompressed in memory.
        sourceTotalMB = sourceTotalPixels / pixelsPerMB;
        // determine the scale ratio to apply to the input image
        // that results in an output image of the defined size.
        // see kDestImageSizeMB, and how it relates to destTotalPixels.
        imageScale = destTotalPixels / sourceTotalPixels;
        // use the image scale to calcualte the output image width, height
        destResolution.width = (int)( sourceResolution.width * imageScale );
        destResolution.height = (int)( sourceResolution.height * imageScale );
        // create an offscreen bitmap context that will hold the output image
        // pixel data, as it becomes available by the downscaling routine.
        // use the RGB colorspace as this is the colorspace iOS GPU is optimized for.
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        int bytesPerRow = bytesPerPixel * destResolution.width;
        // allocate enough pixel data to hold the output image.
        void* destBitmapData = malloc( bytesPerRow * destResolution.height );
        if( destBitmapData == NULL ) NSLog(@"failed to allocate space for the output image!");
        // create the output bitmap context
        self.destContext = CGBitmapContextCreate( destBitmapData, destResolution.width, destResolution.height, 8, bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast );
        // remember CFTypes assign/check for NULL. NSObjects assign/check for nil.
        if(self.destContext == NULL) {
            free( destBitmapData );
            NSLog(@"failed to create the output bitmap context!");
        }
        // release the color space object as its job is done
        CGColorSpaceRelease( colorSpace );
        // flip the output graphics context so that it aligns with the
        // cocoa style orientation of the input document. this is needed
        // because we used cocoa's UIImage -imageNamed to open the input file.
        CGContextTranslateCTM( self.destContext, 0.0f, destResolution.height );
        CGContextScaleCTM( self.destContext, 1.0f, -1.0f );
        // now define the size of the rectangle to be used for the
        // incremental blits from the input image to the output image.
        // we use a source tile width equal to the width of the source
        // image due to the way that iOS retrieves image data from disk.
        // iOS must decode an image from disk in full width 'bands', even
        // if current graphics context is clipped to a subrect within that
        // band. Therefore we fully utilize all of the pixel data that results
        // from a decoding opertion by achnoring our tile size to the full
        // width of the input image.
        sourceTile.size.width = sourceResolution.width;
        // the source tile height is dynamic. Since we specified the size
        // of the source tile in MB, see how many rows of pixels high it
        // can be given the input image width.
        sourceTile.size.height = (int)( tileTotalPixels / sourceTile.size.width );
        NSLog(@"source tile size: %f x %f",sourceTile.size.width, sourceTile.size.height);
        sourceTile.origin.x = 0.0f;
        // the output tile is the same proportions as the input tile, but
        // scaled to image scale.
        destTile.size.width = destResolution.width;
        destTile.size.height = sourceTile.size.height * imageScale;
        destTile.origin.x = 0.0f;
        NSLog(@"dest tile size: %f x %f",destTile.size.width, destTile.size.height);
        // the source seem overlap is proportionate to the destination seem overlap.
        // this is the amount of pixels to overlap each tile as we assemble the ouput image.
        sourceSeemOverlap = (int)( ( destSeemOverlap / destResolution.height ) * sourceResolution.height );
        NSLog(@"dest seem overlap: %f, source seem overlap: %f",destSeemOverlap, sourceSeemOverlap);
        CGImageRef sourceTileImageRef;
        // calculate the number of read/write opertions required to assemble the
        // output image.
        int iterations = (int)( sourceResolution.height / sourceTile.size.height );
        // if tile height doesn't divide the image height evenly, add another iteration
        // to account for the remaining pixels.
        int remainder = (int)sourceResolution.height % (int)sourceTile.size.height;
        if( remainder ) iterations++;
        // add seem overlaps to the tiles, but save the original tile height for y coordinate calculations.
        float sourceTileHeightMinusOverlap = sourceTile.size.height;
        sourceTile.size.height += sourceSeemOverlap;
        destTile.size.height += destSeemOverlap;
        NSLog(@"beginning downsize. iterations: %d, tile height: %f, remainder height: %d", iterations, sourceTile.size.height,remainder );
        for( int y = 0; y < iterations; ++y ) {
            // create an autorelease pool to catch calls to -autorelease made within the downsize loop.
            @autoreleasepool {
                NSLog(@"iteration %d of %d",y+1,iterations);
                sourceTile.origin.y = y * sourceTileHeightMinusOverlap + sourceSeemOverlap;
                destTile.origin.y = ( destResolution.height ) - ( ( y + 1 ) * sourceTileHeightMinusOverlap * imageScale + destSeemOverlap );
                // create a reference to the source image with its context clipped to the argument rect.
                sourceTileImageRef = CGImageCreateWithImageInRect( sourceImage.CGImage, sourceTile );
                // if this is the last tile, it's size may be smaller than the source tile height.
                // adjust the dest tile size to account for that difference.
                if( y == iterations - 1 && remainder ) {
                    float dify = destTile.size.height;
                    destTile.size.height = CGImageGetHeight( sourceTileImageRef ) * imageScale;
                    dify -= destTile.size.height;
                    destTile.origin.y += dify;
                }
                // read and write a tile sized portion of pixels from the input image to the output image.
                CGContextDrawImage( self.destContext, destTile, sourceTileImageRef );
                /* release the source tile portion pixel data. note,
                 releasing the sourceTileImageRef doesn't actually release the tile portion pixel
                 data that we just drew, but the call afterward does. */
                CGImageRelease( sourceTileImageRef );
                /* while CGImageCreateWithImageInRect lazily loads just the image data defined by the argument rect,
                 that data is finally decoded from disk to mem when CGContextDrawImage is called. sourceTileImageRef
                 maintains internally a reference to the original image, and that original image both, houses and
                 caches that portion of decoded mem. Thus the following call to release the source image. */
                // free all objects that were sent -autorelease within the scope of this loop.
                
            }
            // we reallocate the source image after the pool is drained since UIImage -imageNamed
            // returns us an autoreleased object.
            if( y < iterations - 1 ) {
                sourceImage = [[UIImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:filename ofType:nil]];
                [self performSelectorOnMainThread:@selector(updateImageView) withObject:nil waitUntilDone:YES];
            }
        }
        NSLog(@"downsize complete.");
        [self performSelectorOnMainThread:@selector(updateImageView) withObject:nil waitUntilDone:YES];
        self.downsizing = NO;
        free( destBitmapData);
        // free the context since its job is done. destImageRef retains the pixel data now.
        CGContextRelease( self.destContext );
    }
}

-(void)createImageFromContext {
    CGImageRef destImageRef = CGBitmapContextCreateImage( self.destContext );
    if( destImageRef == NULL ) NSLog(@"destImageRef is null.");
    self.image = [UIImage imageWithCGImage:destImageRef scale:1.0f orientation:UIImageOrientationDownMirrored];
    CGImageRelease( destImageRef );
    if( self.image == nil ) NSLog(@"destImage is nil.");
}

-(void)updateImageView {
    [self createImageFromContext];
}

# pragma mark -
- (void)setDownsizing:(BOOL)downsizing {
    objc_setAssociatedObject(self, @selector(downsizing), [NSNumber numberWithBool:downsizing], OBJC_ASSOCIATION_ASSIGN);
}

- (BOOL)downsizing {
    return [objc_getAssociatedObject(self, @selector(downsizing)) boolValue];
}

- (void)setDestContext:(CGContextRef)destContext {
    objc_setAssociatedObject(self, @selector(destContext), (__bridge id)(destContext), OBJC_ASSOCIATION_ASSIGN);
}

- (CGContextRef)destContext {
    return (__bridge CGContextRef)(objc_getAssociatedObject(self, @selector(destContext)));
}

@end
