#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// OpenGL ES surface driven by libmpv's render API.
/// Ownership: the view creates a render context on top of the mpv_handle it is given,
/// and must be detached (before the core is destroyed) or the app will crash.
@interface MPVRenderView : UIView

- (instancetype)initWithFrame:(CGRect)frame mpvHandle:(void *)handle;

/// Fired once the render context is live; load media only after this.
@property (nonatomic, copy, nullable) void (^onReady)(void);

/// Fired with a human-readable reason when render init or a frame fails.
@property (nonatomic, copy, nullable) void (^onFailure)(NSString *reason);

/// Must be called before mpv_terminate_destroy: frees the render context on the GL thread.
- (void)detachRenderer;

@end

NS_ASSUME_NONNULL_END
