//
//  FFImageDecoder.h
//  FFAnimatedImageDemo
//
//  Created by yafengxn on 2017/7/12.
//  Copyright © 2017年 yafengxn. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, FFImageType) {
    FFImageTypeUnknown = 0, ///< unkown
    FFImageTypeJPEG,        ///< jpeg, jpg
    FFImageTypeJPEG2000,    ///< jp2
    FFImageTypeTIFF,        ///< tiff, tif
    FFImageTypeBMP,         ///< bmp
    FFImageTypeICO,         ///< ico
    FFImageTypeICNS,        ///< icns
    FFImageTypeGIF,         ///< gif
    FFImageTypePNG,         ///< png
    FFImageTypeWebP,        ///< webp
    FFImageTypeOther,       ///< other image format
};

typedef NS_ENUM(NSUInteger, FFImageDisposeMethod) {
    FFImageDisposeNone = 0,
    FFImageDisposeBackground,
    FFImageDisposePrevious,
};

typedef NS_ENUM(NSUInteger, FFImageBlendOperation) {
    FFImageBlendNone = 0,
    FFImageBlendOver,
};

@interface FFImageFrame : NSObject<NSCopying>
@property (nonatomic) NSUInteger index;     ///< Frame index (zero based)
@property (nonatomic) NSUInteger width;     ///< Frame width
@property (nonatomic) NSUInteger height;    ///< Frame height
@property (nonatomic) NSUInteger offsetX;   ///< Frame origin.x in canvas (left-bottom based)
@property (nonatomic) NSUInteger offsetY;   ///< Frame origin.y in canvas (left-bottom based)
@property (nonatomic) NSTimeInterval duration;  ///< Frame duration in seconds
@property (nonatomic) FFImageDisposeMethod dispose; ///< Frame dispose method.
@property (nonatomic) FFImageBlendOperation blend;  ///< Frame blend operation.
@property (nullable, nonatomic, strong) UIImage *iamge; ///< The image.
+ (instancetype)frameWithImage:(UIImage *)image;
@end

#pragma mark - Decoder

@interface FFImageDecoder : NSObject

@property (nullable, nonatomic, readonly) NSData *data;     ///< Image data.
@property (nonatomic, readonly) FFImageType type;           ///< Image data type.
@property (nonatomic, readonly) CGFloat scale;              ///< Image scale.
@property (nonatomic, readonly) NSUInteger frameCount;      ///< Image frame count.
@property (nonatomic, readonly) NSUInteger loopCount;       ///< Image loop count, 0 means infinite
@property (nonatomic, readonly) NSUInteger width;           ///< Image canvas width.
@property (nonatomic, readonly) NSUInteger height;          ///< Image canvas height.
@property (nonatomic, readonly, getter=isFinalized) BOOL finalized;

- (instancetype)initWithScale:(CGFloat)scale NS_DESIGNATED_INITIALIZER;
- (BOOL)updateData:(nullable NSData *)data final:(BOOL)final;
- (nullable FFImageFrame *)frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay;
- (NSTimeInterval)frameDurationAtIndex:(NSUInteger)index;
- (nullable NSDictionary *)framePropertiesAtIndex:(NSUInteger)index;
- (nullable NSDictionary *)imageProperties;

@end

#pragma mark - Encoder

@interface FFImageEncoder : NSObject

@property (nonatomic, readonly) FFImageType type;   ///< Image type.
@property (nonatomic) NSUInteger loopCount;         ///< Loop count, 0 means infinite, only available for GIF/APNG/WebP.
@property (nonatomic) BOOL lossless;                ///< Lossless, only available for webP.
@property (nonatomic) CGFloat quaility;             ///< Compress quality, 0.0~1.0, only available for JPG/JP2/WebP

- (instancetype)init UNAVAILABLE_ATTRIBUTE;
+ (instancetype)new UNAVAILABLE_ATTRIBUTE;

- (nullable instancetype)initWithType:(FFImageType)type NS_DESIGNATED_INITIALIZER;
- (void)addImage:(UIImage *)image duration:(NSTimeInterval)duration;
- (void)addImageWithData:(NSData *)data duration:(NSTimeInterval)duration;
- (void)addImageWithFile:(NSString *)path duration:(NSTimeInterval)duration;
- (nullable NSData *)encode;
- (BOOL)encodeToFile:(NSString *)path;
+ (nullable NSData *)encodeImage:(UIImage *)image type:(FFImageType)type quality:(CGFloat)quality;
+ (nullable NSData *)encodeImageWithDecoder:(FFImageDecoder *)decoder type:(FFImageType)type quality:(CGFloat)quality;

@end

#pragma mark - UIImage

@interface UIImage (FFImageCoder)

- (instancetype)ff_iamgeByDecoded;

@property (nonatomic) BOOL ff_isDecodedForDisplay;

- (void)ff_saveToAlbumWithCompletionBlock:(nullable void(^)(NSURL * _Nullable assetURL, NSError * _Nullable error))completionBlock;

- (nullable NSData *)ff_imageDataRepresentation;

@end


#pragma mark - Helper

/// Detect a data's image type by reading the data's header 16 bytes.
CG_EXTERN FFImageType FFImageDetectType(CFDataRef data);

/// Convert FFImageType to UTI (such as kUTTypeJPEG).
CG_EXTERN CFStringRef _Nullable FFImageTypeToUTType(FFImageType type);

/// Convert UTI (such as kUTTypeJPEG) to FFImageType.
CG_EXTERN FFImageType FFImageTypeFromUTType(CFStringRef uti);

/// Get image type's file extension (such as @"jpg")
CG_EXTERN NSString *_Nullable FFImageTypeGetExtentsion(FFImageType type);



/// Return the shared DeviceRGB color space.
CG_EXTERN CGColorSpaceRef FFCGColorSpaceGetDeviceRGB();

/// Return the shared DeviceGray color space;
CG_EXTERN CGColorSpaceRef FFCGColorSpaceGetDeviceGray();

/// Return whether a color sapce is DeviceRGB.
CG_EXTERN BOOL FFCGColorSpaceIsDeviceRGB(CGColorSpaceRef space);

/// Return whether a color sapce is DeviceGray.
CG_EXTERN BOOL FFCGColorSpaceIsDeviceGray(CGColorSpaceRef space);



/// Convert EXIF orientation value to UIImageOrientation.
CG_EXTERN UIImageOrientation FFUIImageOrientationFromEXIFValue(NSInteger value);

/// Convert UIImageOrientation to EXIF orienttation value.
CG_EXTERN NSInteger FFUIImageOrientationToEXIFValue(UIImageOrientation orientation);



/// Create a decoded image.
CG_EXTERN CGImageRef _Nullable FFCGImageCreateDecodedCopy(CGImageRef imageRef, BOOL decodeForDisplay);

/// Create an image copy with an orientation.
CG_EXTERN CGImageRef _Nullable FFCGImageCreateCopyWithOrientation(CGImageRef imageRef,
                                                                  UIImageOrientation orientation,
                                                                  CGBitmapInfo destBitmapInfo);

/// Create an image copy with CGAffineTransform.
CG_EXTERN CGImageRef _Nullable FFCGImageCreateAffineTransformCopy(CGImageRef imageRef,
                                                                 CGAffineTransform transform,
                                                                 CGSize destSize,
                                                                 CGBitmapInfo destBitmapInfo);

/// Encode an image to data with CGImageDestination.
CG_EXTERN CFDataRef _Nullable FFCGImageCreateEncodedData(CGImageRef imageRef,
                                                         FFImageType type,
                                                         CGFloat quality);

/// Whether WebP is available in FFImage.
CG_EXTERN BOOL FFImageWebPAvailable();

/// Get a webp iamge frame count.
CG_EXTERN NSUInteger FFImageGetWebPFrameCount(CFDataRef webpData);

/// Decode an image from WebP data, returns NULL if an error occurs.
CG_EXTERN CGImageRef _Nullable FFCGImageCreateWithData(CFDataRef webpData,
                                                       BOOL decodeForDisplay,
                                                       BOOL useThreads,
                                                       BOOL bypassFiltering,
                                                       BOOL noFancyUpsampling);

typedef NS_ENUM(NSUInteger, FFImagePreset) {
    FFImagePresetDefault = 0,   ///< default preset
    FFImagePresetPicuture,      ///< digital picture, like portrait, inner shot
    FFImagePresetPhoto,         ///< outdoor photograph, with natural lighting
    FFImagePresetDrawing,       ///< hand or line drawing,with high-contrast details
    FFImagePresetIcon,          ///< small-sized colorful images
    FFImagePresetText           ///< text-like
};

/// Encode a CGImage to WebP data.
CG_EXTERN CFDataRef _Nullable FFCGImageCreateEncodedWebPData(CGImageRef imageRef,
                                                             BOOL lossless,
                                                             CGFloat quality,
                                                             int compressLevel,
                                                             FFImagePreset preset);

NS_ASSUME_NONNULL_END
