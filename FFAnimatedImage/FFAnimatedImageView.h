//
//  FFAnimatedImageView.h
//  FFAnimatedImageDemo
//
//  Created by yafengxn on 2017/7/10.
//  Copyright © 2017年 yafengxn. All rights reserved.
//

#import <UIKit/UIKit.h>


NS_ASSUME_NONNULL_BEGIN

@interface FFAnimatedImageView : UIImageView

@property (nonatomic) BOOL autoPlayAnimatedImage;

@property (nonatomic) NSUInteger currentAnimatedImageIndex;

@property (nonatomic, readonly) BOOL currentIsPlayingAnimation;

@property (nonatomic, copy) NSString *runLoopMode;

@property (nonatomic) NSUInteger maxBufferSize;

@end


@protocol FFAnimatedImage <NSObject>
@required
- (NSUInteger)animatedImageFrameCount;

- (NSUInteger)animatedImageLoopCount;

- (NSUInteger)animatedImageBytesPerFrame;

- (nullable UIImage *)animatedImageFrameAtIndex:(NSUInteger)index;

- (NSTimeInterval)animatedImageDurationAtIndex:(NSUInteger)index;

@optional
- (CGRect)animtedImageContentsRectAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
