#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// OpenGL ES surface driven by libmpv's render API.
/// Pass the mpv_handle created by MPVEngine; the view owns the render context.
@interface MPVRenderView : UIView

- (instancetype)initWithFrame:(CGRect)frame mpvHandle:(void *)handle;

/// Called with a human-readable reason when render init or a frame fails.
@property (nonatomic, copy, nullable) void (^onFailure)(NSString *reason);

@end

NS_ASSUME_NONNULL_END
