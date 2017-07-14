//
//  FFImage.h
//  FFAnimatedImageDemo
//
//  Created by yafengxn on 2017/7/12.
//  Copyright © 2017年 yafengxn. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "FFAnimatedImageView.h"
#import "FFImageDecoder.h"

FOUNDATION_EXPORT double FFImageVersionNumber;
FOUNDATION_EXPORT const unsigned char FFImageVersionString[];

NS_ASSUME_NONNULL_BEGIN

@interface FFImage : UIImage<FFAnimatedImage>

+ (nullable FFImage *)imageNamed:(NSString *)name;  // no cache!
+ (nullable FFImage *)imageWithContentsOfFile:(NSString *)path;
+ (nullable FFImage *)imageWithData:(NSData *)data;
+ (nullable FFImage *)imageWithData:(NSData *)data scale:(CGFloat)scale;

@property (nonatomic, readonly) FFImageType animatedImageType;
@property (nullable, nonatomic, readonly) NSData *animatedImageData;
@property (nonatomic, readonly) NSUInteger animatedImageMemorySize;
@property (nonatomic) BOOL preloadAllAnimatedImageFrames;
@end

NS_ASSUME_NONNULL_END
