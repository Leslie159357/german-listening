#import "MPVRenderView.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

// libmpv render API, declared locally: MPVKit ships binary frameworks without public headers.
typedef void mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct { int type; void *data; } mpv_render_param;

typedef struct {
    void *(*get_proc_address)(void *ctx, const char *name);
    void *get_proc_address_ctx;
} mpv_opengl_init_params;

typedef struct {
    int fbo;
    int w;
    int h;
    int internal_format;
} mpv_opengl_fbo;

typedef void (*mpv_render_update_fn)(void *cb_ctx);

enum {
    MPV_RENDER_PARAM_INVALID = 0,
    MPV_RENDER_PARAM_API_TYPE = 1,
    MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
    MPV_RENDER_PARAM_OPENGL_FBO = 3,
    MPV_RENDER_PARAM_FLIP_Y = 4,
};

// return type is int (error code); the context comes back through the first argument
extern int mpv_render_context_create(mpv_render_context **res, void *mpv, mpv_render_param *params);
extern int mpv_render_context_render(mpv_render_context *ctx, mpv_render_param *params);
extern void mpv_render_context_set_update_callback(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx);
extern void mpv_render_context_free(mpv_render_context *ctx);
extern void mpv_render_context_report_swap(mpv_render_context *ctx);

static const char *kMPVRenderAPITypeOpenGL = "opengl";

static void mpvRenderUpdate(void *cb_ctx);

static void *mpv_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) { return symbol; }
    // Fallback for symbols not exported to the global namespace.
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengles"));
    if (bundle) { return CFBundleGetFunctionPointerForName(bundle, (__bridge CFStringRef)[NSString stringWithUTF8String:name]); }
    return NULL;
}

@interface MPVRenderView () {
    BOOL _setupTried;
}
- (void)drawFrame;
- (void)setupGL;
- (void)resizeDrawable;

@property (nonatomic, assign) void *mpvHandle;
@property (nonatomic, assign) mpv_render_context *renderContext;
@property (nonatomic, strong) EAGLContext *glContext;
@property (nonatomic, assign) GLuint framebuffer;
@property (nonatomic, assign) GLuint colorRenderbuffer;
@property (nonatomic, assign) CGSize pixelSize;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, assign) BOOL needsResize;
@property (nonatomic, assign) BOOL ready;
@end

@implementation MPVRenderView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame mpvHandle:(void *)handle {
    self = [super initWithFrame:frame];
    if (!self) { return nil; }
    _mpvHandle = handle;
    _renderQueue = dispatch_queue_create("xyz.1122275.mpv.render", DISPATCH_QUEUE_SERIAL);
    self.opaque = YES;
    self.backgroundColor = [UIColor blackColor];
    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    layer.opaque = YES;
    layer.drawableProperties = @{
        kEAGLDrawablePropertyRetainedBacking: @NO,
        kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
    };
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self setupGLIfNeeded];
    } else {
        // Leaving the hierarchy: stop mpv from calling back into a view that may go away.
        if (self.renderContext) {
            mpv_render_context_set_update_callback(self.renderContext, NULL, NULL);
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self setupGLIfNeeded];
    if (!self.ready) { return; }
    dispatch_async(self.renderQueue, ^{ [self resizeDrawable]; [self drawFrame]; });
}

- (void)setupGLIfNeeded {
    if (self.ready || _setupTried) { return; }
    _setupTried = YES;              // attempt exactly once: a failure must not leak GL objects
    [self setupGL];
}

- (void)setupGL {
    if (self.mpvHandle == NULL) {
        [self reportFailure:@"mpv handle 为空"];
        return;
    }
    self.glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!self.glContext) { self.glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2]; }
    if (!self.glContext) { [self reportFailure:@"EAGLContext 创建失败"]; return; }
    if (![EAGLContext setCurrentContext:self.glContext]) { [self reportFailure:@"EAGLContext 无法激活"]; return; }

    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer);
    glGenRenderbuffers(1, &_colorRenderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);

    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    layer.contentsScale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2.0;
    if (![self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) {
        [self reportFailure:@"renderbufferStorage 失败"]; return;
    }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.colorRenderbuffer);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        [self reportFailure:@"framebuffer 不完整"]; return;
    }

    mpv_opengl_init_params initParams = { mpv_get_proc_address, NULL };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE, (void *)kMPVRenderAPITypeOpenGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &initParams },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    mpv_render_context *ctx = NULL;
    int rc = mpv_render_context_create(&ctx, self.mpvHandle, params);
    if (rc < 0 || ctx == NULL) {
        [self reportFailure:[NSString stringWithFormat:@"mpv render init 失败 (rc=%d) —— 多半是 vo 不是 libmpv 或 GL 版本不足", rc]];
        return;
    }
    self.renderContext = ctx;

    __weak MPVRenderView *weakSelf = self;
    mpv_render_context_set_update_callback(ctx, mpvRenderUpdate, (__bridge void *)weakSelf);
    // The render queue takes over the context; do not leave it current on the main thread.
    self.ready = YES;
    [EAGLContext setCurrentContext:nil];
    if (self.onReady) { self.onReady(); }
}

static void mpvRenderUpdate(void *cb_ctx) {
    // cb_ctx is unretained: resolve weakly so a dying view cannot be messaged.
    __weak MPVRenderView *weakView = (__bridge MPVRenderView *)cb_ctx;
    MPVRenderView *view = weakView;
    if (!view || !view.ready || view.renderQueue == nil) { return; }
    dispatch_async(view.renderQueue, ^{
        MPVRenderView *strongView = weakView;
        if (!strongView || !strongView.ready) { return; }
        [strongView drawFrame];
    });
}

- (void)resizeDrawable {
    if (!self.ready || !self.glContext) { return; }
    [EAGLContext setCurrentContext:self.glContext];
    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    if (![self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer]) { return; }
    GLint width = 0, height = 0;
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
    self.pixelSize = CGSizeMake(width, height);
}

- (void)drawFrame {
    if (!self.ready || self.renderContext == NULL || !self.glContext) { return; }
    if (self.pixelSize.width < 1 || self.pixelSize.height < 1) { return; }
    if (![EAGLContext setCurrentContext:self.glContext]) { return; }

    glBindFramebuffer(GL_FRAMEBUFFER, self.framebuffer);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    // EAGL has no default framebuffer: drawing into 0 paints into nothing.
    // internal_format 0 = unknown, let mpv query it; a wrong hint can swap colour channels.
    mpv_opengl_fbo fbo = { (int)self.framebuffer,
                           (int)self.pixelSize.width,
                           (int)self.pixelSize.height,
                           0 };
    int flipY = 1;
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y, &flipY },
        { MPV_RENDER_PARAM_INVALID, NULL }
    };
    int rc = mpv_render_context_render(self.renderContext, params);
    if (rc < 0) {
        [self reportFailure:[NSString stringWithFormat:@"render 返回 %d", rc]];
        return;
    }
    glBindRenderbuffer(GL_RENDERBUFFER, self.colorRenderbuffer);
    [self.glContext presentRenderbuffer:GL_RENDERBUFFER];
    mpv_render_context_report_swap(self.renderContext);
}

- (void)reportFailure:(NSString *)reason {
    self.ready = NO;
    if (self.onFailure) { self.onFailure(reason); }
}

- (void)detachRenderer {
    if (self.renderContext) {
        [EAGLContext setCurrentContext:self.glContext];   // mpv requires the creating context to be current
        mpv_render_context_set_update_callback(self.renderContext, NULL, NULL);
        mpv_render_context_free(self.renderContext);
        self.renderContext = NULL;
    }
    self.ready = NO;
    self.mpvHandle = NULL;
}

- (void)dealloc {
    [self detachRenderer];
    if (_framebuffer || _colorRenderbuffer) {
        [EAGLContext setCurrentContext:self.glContext];
        if (_framebuffer) { glDeleteFramebuffers(1, &_framebuffer); }
        if (_colorRenderbuffer) { glDeleteRenderbuffers(1, &_colorRenderbuffer); }
        [EAGLContext setCurrentContext:nil];
    }
}

@end
