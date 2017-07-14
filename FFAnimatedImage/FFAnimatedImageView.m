//
//  FFAnimatedImageView.m
//  FFAnimatedImageDemo
//
//  Created by yafengxn on 2017/7/10.
//  Copyright © 2017年 yafengxn. All rights reserved.
//

#import "FFAnimatedImageView.h"
#import <mach/mach.h>
#import <pthread.h>

#define BUFFERSIZE (10 * 1024 * 1024)   // 10MB (minimum buffer size)

#define LOCK(...) dispatch_semaphore_wait(self->_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(self->_lock);

#define LOCK_View(...) dispatch_semaphore_wait(view->_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(view->_lock);

static int64_t __FFDeviceMemoryTotal() {
    int64_t mem = [[NSProcessInfo processInfo] physicalMemory];
    if (mem < -1) mem = -1;
    return mem;
}

static int64_t __FFDeviceMemoryFree() {
    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics_t) / sizeof(integer_t);
    vm_size_t page_size;
    vm_statistics_data_t vm_stat;
    kern_return_t kern;
    
    kern = host_page_size(host_port, &page_size);
    if (kern != KERN_SUCCESS) return -1;
    kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
    if (kern != KERN_SUCCESS) return -1;
    return vm_stat.free_count * page_size;
}

@interface _FFImageWeakProxy : NSProxy
@property (nonatomic, weak, readonly) id target;
+ (instancetype)proxyWithTarget:(id)target;
@end

@implementation _FFImageWeakProxy
- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}
+ (instancetype)proxyWithTarget:(id)target {
    return [[_FFImageWeakProxy alloc] initWithTarget:target];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return _target;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    void *null = NULL;
    [invocation setReturnValue:null];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}
- (BOOL)isEqual:(id)object {
    return [_target isEqual:object];
}
- (NSUInteger)hash {
    return [_target hash];
}
- (Class)superclass {
    return [_target superclass];
}
- (Class)class {
    return [_target class];
}
- (BOOL)isKindOfClass:(Class)aClass {
    return [_target isKindOfClass:aClass];
}
- (BOOL)isMemberOfClass:(Class)aClass {
    return [_target isMemberOfClass:aClass];
}
- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return [_target conformsToProtocol:aProtocol];
}
- (BOOL)isProxy {
    return YES;
}
- (NSString *)description {
    return [_target description];
}
- (NSString *)debugDescription {
    return [_target debugDescription];
}
@end


typedef NS_ENUM(NSUInteger, FFAnimatedImageType) {
    FFAnimatedImageTypeNone = 0,
    FFAnimatedImageTypeImage,
    FFAnimatedImageTypeHighligthedImage,
    FFAnimatedImageTypeImages,
    FFAnimatedImageTypeHighlightedImages,
};


@interface FFAnimatedImageView() {
    @package
    UIImage <FFAnimatedImage> *_curAnimatedImage;
    
    dispatch_once_t _onceToken;
    dispatch_semaphore_t _lock; ///< lock for _buffer
    NSOperationQueue *_requestQueue;   ///< time after last frame
    
    CADisplayLink *_link;   ///< ticker for  change frame
    NSTimeInterval _time;   ///< time after last frame
    
    UIImage *_curFrame;    ///< current frame to display
    NSUInteger _curIndex;   ///< current frame index (from 0)
    NSUInteger _totalFrameCount;    ///<total frame count
    
    BOOL _loopEnd;  ///< whether the loop is end
    NSUInteger _curLoop;    ///< current loop count (from 0)
    NSUInteger _totalLoop;  ///< total loop count, 0 means infinity
    
    NSMutableDictionary *_buffer;   ///< frame buffer
    BOOL _bufferMiss;   ///< whether miss frame on last opportunity
    NSUInteger _maxBufferCount;     ///< maximum buffer count
    NSInteger _incrBufferCount;     ///< current allowed buffer count (will increase by step)
    
    CGRect _curContentsRect;
    BOOL _curImageHasContentsRect;  ///< image has implementated "animtedImageContentsRectAtIndex:"
}
@property (nonatomic, readwrite) BOOL currentIsPlayingAnimation;
- (void)calcMaxBufferCount;
@end

@interface _FFAnimatedImageViewFetchOperation : NSOperation
@property (nonatomic, weak) FFAnimatedImageView *view;
@property (nonatomic, assign) NSUInteger nextIndex;
@property (nonatomic, strong) UIImage<FFAnimatedImage> *curImage;
@end

@implementation _FFAnimatedImageViewFetchOperation

- (void)main {
    __strong FFAnimatedImageView *view = _view;
    if (!view) return;
    if ([self isCancelled]) return;
    view->_incrBufferCount++;
    if (view->_incrBufferCount == 0) [view calcMaxBufferCount];
    if (view->_incrBufferCount > (NSInteger)view->_maxBufferCount) {
        view->_incrBufferCount = view->_maxBufferCount;
    }
    NSUInteger idx = _nextIndex;
    NSUInteger max = view->_incrBufferCount < 1? 1 : view->_incrBufferCount;
    NSUInteger total = view->_totalFrameCount;
    view = nil;
    
    for (int i = 0; i < max; i++, idx++) {
        @autoreleasepool {
            if (idx >= total) idx = 0;
            if ([self isCancelled]) break;
            __strong FFAnimatedImageView *view = _view;
            if (!view) break;
            LOCK_View(BOOL miss = (view->_buffer[@(idx)] == nil));
            
            if (miss) {
                UIImage *img = [_curImage animatedImageFrameAtIndex:idx];
                img = img.ff_imageByDecoded;
                if ([self isCancelled]) break;
                LOCK_View(view->_buffer[@(idx)] = img? img : [NSNull null])
            }
        }
    }
}

@end

@implementation FFAnimatedImageView
- (instancetype)init {
    if (self = [super init]) {
        _runLoopMode = NSRunLoopCommonModes;
        _autoPlayAnimatedImage = YES;
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _runLoopMode = NSRunLoopCommonModes;
        _autoPlayAnimatedImage = YES;
    }
    return self;
}

- (instancetype)initWithImage:(UIImage *)image {
    if (self = [super initWithImage:image]) {
        self.frame = (CGRect){CGPointZero, image.size};
        self.image = image;
    }
    return self;
}

- (instancetype)initWithImage:(UIImage *)image highlightedImage:(UIImage *)highlightedImage {
    if (self = [super initWithImage:image]) {
        self.frame = (CGRect){CGPointZero, image.size};
        self.image = image;
        self.highlightedImage = highlightedImage;
    }
    return self;
}

- (void)setImage:(UIImage *)image {
    if (self.image == image) return;
    [self setImage:image withType:FFAnimatedImageTypeImage];
}

- (void)setHighlightedImage:(UIImage *)highlightedImage {
    if (self.highlightedImage == highlightedImage) return;
    [self setImage:highlightedImage withType:FFAnimatedImageTypeImage];
}

- (void)setAnimationImages:(NSArray<UIImage *> *)animationImages {
    if (self.animationImages == animationImages) return;
    [self setImage:animationImages withType:FFAnimatedImageTypeImages];
}

- (void)setHighlightedAnimationImages:(NSArray<UIImage *> *)highlightedAnimationImages {
    if (self.highlightedAnimationImages == highlightedAnimationImages) return;
    [self setImage:highlightedAnimationImages withType:FFAnimatedImageTypeHighlightedImages];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (_link) [self resetAnimated];
    [self imageChanged];
}

- (void)setImage:(id)image withType:(FFAnimatedImageType)type {
    [self stopAnimating];
    if (_link) [self resetAnimated];
    _curFrame = nil;
    switch (type) {
        case FFAnimatedImageTypeNone: break;
        case FFAnimatedImageTypeImage: super.image = image; break;
        case FFAnimatedImageTypeHighligthedImage: super.highlightedImage = image; break;
        case FFAnimatedImageTypeImages: super.animationImages = image; break;
        case FFAnimatedImageTypeHighlightedImages: super.highlightedAnimationImages = image; break;
    }
    [self imageChanged];
}

- (void)imageChanged {
    FFAnimatedImageType newType = [self currentImageType];
    id newVisibleImage = [self imageForType:newType];
    NSUInteger newImageFrameCount = 0;
    BOOL hasContentsRect = NO;
    if ([newVisibleImage isKindOfClass:[UIImage class]] &&
        [newVisibleImage conformsToProtocol:@protocol(FFAnimatedImage)]) {
        newImageFrameCount = ((UIImage<FFAnimatedImage> *)newVisibleImage).animatedImageLoopCount;
        if (newImageFrameCount > 1) {
            hasContentsRect = [(UIImage<FFAnimatedImage> *)newVisibleImage respondsToSelector:
                               @selector(animtedImageContentsRectAtIndex:)];
        }
    }
    if (hasContentsRect && _curImageHasContentsRect) {
        if (!CGRectEqualToRect(self.layer.contentsRect, CGRectMake(0, 0, 1, 1))) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            self.layer.contentsRect = CGRectMake(0, 0, 1, 1);
            [CATransaction commit];
        }
    }
    _curImageHasContentsRect = hasContentsRect;
    if (hasContentsRect) {
        CGRect rect = [((UIImage<FFAnimatedImage> *) newVisibleImage) animtedImageContentsRectAtIndex:0];
        [self setContentsRect:rect forImage:newVisibleImage];
    }
    
    if (newImageFrameCount > 1) {
        [self resetAnimated];
        _curAnimatedImage = newVisibleImage;
        _curFrame = newVisibleImage;
        _totalLoop = _curAnimatedImage.animatedImageLoopCount;
        _totalFrameCount = _curAnimatedImage.animatedImageFrameCount;
        [self calcMaxBufferCount];
    }
    [self setNeedsDisplay];
    [self didMoved];
}

- (id)imageForType:(FFAnimatedImageType)type {
    switch (type) {
        case FFAnimatedImageTypeNone: return nil; break;
        case FFAnimatedImageTypeImage: return self.image; break;
        case FFAnimatedImageTypeImages: return self.animationImages; break;
        case FFAnimatedImageTypeHighligthedImage: return self.highlightedImage; break;
        case FFAnimatedImageTypeHighlightedImages: return self.highlightedAnimationImages; break;
    }
    return nil;
}

- (FFAnimatedImageType)currentImageType {
    FFAnimatedImageType curType = FFAnimatedImageTypeNone;
    if (self.highlighted) {
        if (self.highlightedAnimationImages.count) {
            curType = FFAnimatedImageTypeHighlightedImages;
        } else if (self.highlighted) {
            curType = FFAnimatedImageTypeHighligthedImage;
        }
    }
    if (curType == FFAnimatedImageTypeNone) {
        if (self.animationImages.count) {
            curType = FFAnimatedImageTypeImages;
        } else if (self.image) {
            curType = FFAnimatedImageTypeImage;
        }
    }
    return curType;
}

// init the animated params.
- (void)resetAnimated {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _lock = dispatch_semaphore_create(1);
        _buffer = [NSMutableDictionary new];
        _requestQueue = [[NSOperationQueue alloc] init];
        _requestQueue.maxConcurrentOperationCount = 1;
        _link = [CADisplayLink displayLinkWithTarget:[_FFImageWeakProxy proxyWithTarget:self] selector:@selector(step:)];
        if (_runLoopMode) {
            [_link addToRunLoop:[NSRunLoop currentRunLoop] forMode:_runLoopMode];
        }
        _link.paused = YES;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    });
    
    [_requestQueue cancelAllOperations];
    LOCK(
         if (_buffer.count) {
             NSMutableDictionary *holder = _buffer;
             _buffer = [NSMutableDictionary new];
             dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                 // Capture the dictionary to global queue,
                 // release these images in background to avoid blocking UI thread.
                 [holder class];
             });
         }
    );
    _link.paused = YES;
    _time = 0;
    if (_curIndex != 0) {
        [self willChangeValueForKey:@"currentAnimatedImageIndex"];
        _curIndex = 0;
        [self didChangeValueForKey:@"currentAnimatedImageIndex"];
    }
    _curAnimatedImage = nil;
    _curFrame = nil;
    _curLoop = 0;
    _totalLoop = 0;
    _totalFrameCount = 1;
    _loopEnd = NO;
    _bufferMiss = NO;
    _incrBufferCount = 0;
}

- (void)step:(CADisplayLink *)link {
    UIImage<FFAnimatedImage> *image = _curAnimatedImage;
    NSMutableDictionary *buffer = _buffer;
    UIImage *bufferedImage = nil;
    NSUInteger nextIndex = (_curIndex + 1) % _totalFrameCount;
    BOOL bufferIsFull = NO;
    
    if (!image) return;
    if (_loopEnd) {
        [self stopAnimating];
        return;
    }
    
    NSTimeInterval delay = 0;
    if (!_bufferMiss) {
        _time += link.duration;
        delay = [image animatedImageDurationAtIndex:_curIndex];
        if (_time < delay) return;
        _time -= delay;
        if (nextIndex == 0) {
            _curLoop++;
            if (_curLoop >= _totalLoop && _totalLoop != 0) {
                _loopEnd = YES;
                [self stopAnimating];
                [self.layer setNeedsDisplay];
                return;
            }
        }
        delay = [image animatedImageDurationAtIndex:nextIndex];
        if (_time > delay) _time = delay;
    }
    LOCK(
         bufferedImage = buffer[@(nextIndex)];
         if (bufferedImage) {
             if ((int)_incrBufferCount < _totalFrameCount) {
                 [buffer removeObjectForKey:@(nextIndex)];
             }
             [self willChangeValueForKey:@"currentAnimatedImageIndex"];
             _curIndex = nextIndex;
             [self didChangeValueForKey:@"currentAnimatedImageIndex"];
             _curFrame = bufferedImage == (id)[NSNull null] ? nil : bufferedImage;
             if (_curImageHasContentsRect) {
                 _curContentsRect = [image animtedImageContentsRectAtIndex:_curIndex];
                 [self setContentsRect:_curContentsRect forImage:_curFrame];
             }
         } else {
             _bufferMiss = YES;
         }
    )//LOCK
    
    if (!_bufferMiss) {
        [self.layer setNeedsDisplay];
    }
    
    if (!bufferIsFull && _requestQueue.operationCount == 0) {
        _FFAnimatedImageViewFetchOperation *operation = [_FFAnimatedImageViewFetchOperation new];
        operation.view = self;
        operation.nextIndex = nextIndex;
        operation.curImage = image;
        [_requestQueue addOperation:operation];
    }
}

- (void)stopAnimating {
    [super stopAnimating];
    [_requestQueue cancelAllOperations];
    _link.paused = YES;
    self.currentIsPlayingAnimation = NO;
}

- (void)startAnimating {
    FFAnimatedImageType type = [self currentImageType];
    if (type == FFAnimatedImageTypeHighlightedImages || type == FFAnimatedImageTypeHighlightedImages) {
        NSArray *images = [self imageForType:type];
        if (images.count > 0) {
            [super startAnimating];
            self.currentIsPlayingAnimation = YES;
        } else {
            if (_curAnimatedImage && _link.paused) {
                _curLoop = 0;
                _loopEnd = NO;
                _link.paused = NO;
                self.currentIsPlayingAnimation = YES;
            }
        }
    }
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    [_requestQueue cancelAllOperations];
    [_requestQueue addOperationWithBlock:^{
        _incrBufferCount = -60 - (int)(arc4random() % 120);
        NSNumber *next = @((_curIndex + 1) % _totalFrameCount);
        LOCK(
             NSArray * keys = _buffer.allKeys;
             for (NSNumber *key in keys) {
                 if (![key isEqualToNumber:next]) {
                     [_buffer removeObjectForKey:key];
                 }
             }
        )//LOCK
    }];
}

- (void)didEnterBackground:(NSNotification *)notification {
    [_requestQueue cancelAllOperations];
    NSNumber *next = @((_curIndex + 1) % _totalFrameCount);
    LOCK(
         NSArray *keys = _buffer.allKeys;
         for (NSNumber *key in keys) {
             if (![key isEqualToNumber:next]) {
                 [_buffer removeObjectForKey:key];
             }
         }
    )//LOCK
}

- (void)calcMaxBufferCount {
    int64_t bytes = (int64_t)_curAnimatedImage.animatedImageBytesPerFrame;
    if (bytes == 0) bytes = 1024;
    
    int64_t total = __FFDeviceMemoryTotal();
    int64_t free = __FFDeviceMemoryFree();
    int64_t max = MIN(total * 0.2, free * 0.6);
    max = MAX(max, BUFFERSIZE);
    if (_maxBufferSize) max = max > _maxBufferSize? _maxBufferSize : max;
    double maxBufferCount = (double)max / (double)bytes;
    if (maxBufferCount < 1) maxBufferCount = 1;
    else if (maxBufferCount > 512) maxBufferCount = 512;
    _maxBufferCount = maxBufferCount;
}

- (void)displayLayer:(CALayer *)layer {
    if (_curFrame) {
        layer.contents = (__bridge id)_curFrame.CGImage;
    }
}

- (void)setContentsRect:(CGRect)rect forImage:(UIImage *)image {
    CGRect layerRect = CGRectMake(0, 0, 1, 1);
    if (image) {
        CGSize imageSize = image.size;
        if (image.size.width > 0.01 && image.size.height > 0.01) {
            layerRect.origin.x = rect.origin.x / imageSize.width;
            layerRect.origin.y = rect.origin.y / imageSize.height;
            layerRect.size.width = rect.size.width / imageSize.width;
            layerRect.size.height = rect.size.height / imageSize.height;
            layerRect = CGRectIntersection(layerRect, CGRectMake(0, 0, 1, 1));
            if (CGRectIsNull(layerRect) || CGRectIsEmpty(layerRect)) {
                layerRect = CGRectMake(0, 0, 1, 1);
            }
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contentsRect = layerRect;
    [CATransaction commit];
}

- (void)didMoved {
    if (self.autoPlayAnimatedImage) {
        if (self.superview && self.window) {
            [self startAnimating];
        } else {
            [self stopAnimating];
        }
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self didMoved];
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [self didMoved];
}

- (void)setCurrentAnimatedImageIndex:(NSUInteger)currentAnimatedImageIndex {
    if (!_curAnimatedImage) return;
    if (currentAnimatedImageIndex >= _curAnimatedImage.animatedImageFrameCount) return;
    if (_curIndex == currentAnimatedImageIndex) return;
    
    void (^block)() = ^{
        LOCK(
             [_requestQueue cancelAllOperations];
             [_buffer removeAllObjects];
             [self willChangeValueForKey:@"currentAnimatedImageIndex"];
             _curIndex = currentAnimatedImageIndex;
             [self didChangeValueForKey:@"currentAnimatedImageIndex"];
             _curFrame = [_curAnimatedImage animatedImageFrameAtIndex:_curIndex];
             if (_curImageHasContentsRect) {
                 _curContentsRect = [_curAnimatedImage animtedImageContentsRectAtIndex:_curIndex];
             }
             _time = 0;
             _loopEnd = NO;
             _bufferMiss = NO;
             [self.layer setNeedsDisplay];
        )//LOCK
    };
    
    if (pthread_main_np()) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

-  (NSUInteger)currentAnimatedImageIndex {
    return _curIndex;
}

- (void)setRunLoopMode:(NSString *)runLoopMode {
    if ([_runLoopMode isEqualToString:runLoopMode]) return;
    if (_link) {
        if (_runLoopMode) {
            [_link removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:_runLoopMode];
        }
        if (runLoopMode.length) {
            [_link addToRunLoop:[NSRunLoop currentRunLoop] forMode:runLoopMode];
        }
    }
    _runLoopMode = runLoopMode.copy;
}

#pragma mark - Override NSObject(NSKeyValueObservingCustomization)
+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    if ([key isEqualToString:@"currentAnimatedImageIndex"]) {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}

#pragma mark - NSCoding
- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        _runLoopMode = [aDecoder decodeObjectForKey:@"runloopMode"];
        if (_runLoopMode.length == 0) _runLoopMode = NSRunLoopCommonModes;
        if ([aDecoder containsValueForKey:@"autoPlayAnimatedImage"]) {
            _autoPlayAnimatedImage = [aDecoder decodeObjectForKey:@"autoPlayAnimatedImage"];
        } else {
            _autoPlayAnimatedImage = YES;
        }
        
        UIImage *image = [aDecoder decodeObjectForKey:@"FFAnimatedImage"];
        UIImage *highlightedImage = [aDecoder decodeObjectForKey:@"FFHighlightedAnimatedImage"];
        if (image) {
            self.image = image;
            [self setImage:image withType:FFAnimatedImageTypeImage];
        }
        if (highlightedImage) {
            self.highlightedImage = image;
            [self setImage:highlightedImage withType:FFAnimatedImageTypeHighligthedImage];
        }
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [super encodeWithCoder:aCoder];
    [aCoder encodeObject:_runLoopMode forKey:@"runloopMode"];
    [aCoder encodeBool:_autoPlayAnimatedImage forKey:@"autoPlayAnimatedImage"];
    
    BOOL ani, multi;
    ani = [self.image conformsToProtocol:@protocol(FFAnimatedImage)];
    multi = (ani && ((UIImage<FFAnimatedImage> *)self.image).animatedImageFrameCount > 1);
    if (multi) [aCoder encodeObject:self.highlightedImage forKey:@"FFHighlightedAnimatedImage"];
}


@end
