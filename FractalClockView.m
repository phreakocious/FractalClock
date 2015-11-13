//
//  FractalClockView.m
//  FractalClock
//
//  Created by Rob Mayoff on 5/20/07.
//  Copyright (c) 2007, Rob Mayoff. Dedicated to the public domain.
//

#define CGL_MACRO_CACHE_RENDERER

#import "FractalClockView.h"
#import "math.h"
#import "time.h"
#import "OpenGL/gl.h"
//#import "OpenGL/CGLMacro.h"
#import "OpenGL/CGLCurrent.h"
#import "OpenGL/CGLContext.h"
#import "stdarg.h"

#define MaxDepth 32 // Far too big for any mortal computer
#define FramesPerSecond 24.
#define ColorAdjustment 0.85

// I use these variables to track CPU usage and tune the recursion depth accordingly.
static NSTimeInterval accumulatedSeconds;
static double accumulatedFrames;
static double framesBetweenDepthChanges;
static unsigned int targetDepth;
static unsigned int viewsCount;
static double totalPixelCount;
static CGLContextObj cgl_ctx;
static GLIContext cgl_rend;

typedef float Rotator[2];
float alphaForDepth[MaxDepth];

static double
transition(double now, double transitionSeconds, ...)
{
    va_list ap;
    
    double totalSeconds = 0;
    va_start(ap, transitionSeconds);
    while (1) {
        double seconds = va_arg(ap, double);
        if (seconds == 0)
            break;
        totalSeconds += seconds + transitionSeconds;
        va_arg(ap, double);
    }
    va_end(ap);
    
    double modnow = fmod(now, totalSeconds);
    double level0;
    va_start(ap, transitionSeconds);
    va_arg(ap, double);
    level0 = va_arg(ap, double);
    va_end(ap);

    double startLevel, endLevel;
    va_start(ap, transitionSeconds);
    while (1) {
        double seconds = va_arg(ap, double);
        startLevel = va_arg(ap, double);
        
        if (modnow < seconds) {
            endLevel = startLevel;
            break;
        }
        
        modnow -= seconds;
        if (modnow <= transitionSeconds) {
            seconds = va_arg(ap, double);
            endLevel = (seconds == 0) ? level0 : va_arg(ap, double);
            break;
        }
        
        modnow -= transitionSeconds;
    }
    va_end(ap);
    
    if (startLevel == endLevel)
        return startLevel;
    
    else {
        return endLevel + (startLevel - endLevel) *
            (cos(M_PI*modnow/transitionSeconds) + 1) * .5;
    }
}

/** Set `rotator' to the top half of the rotation matrix for a rotation of `rotation' (1 = a full revolution), scaled by `scale'. */

static void
initRotator(Rotator rotator, double rotation, double scale)
{
    double radians = 2 * M_PI * rotation;
    rotator[0] = cos(radians) * scale;
    rotator[1] = sin(radians) * scale;
}

/** Apply `rotator' to the vector described by `s0', returning a new vector. */

static NSSize
rotateSize(Rotator rotator, NSSize s0)
{
    return NSMakeSize(
        s0.width * rotator[0] - s0.height * rotator[1],
        s0.width * rotator[1] + s0.height * rotator[0]);
}

/** Return the number of seconds since midnight, local time.  If isPreview is YES, speed time up for more action in the preview window. */

static double
getNow(BOOL isPreview)
{
    double now = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
    struct tm tms;
    time_t tt = (time_t)now;
    localtime_r(&tt, &tms);
    now = ((tms.tm_hour * 60) + tms.tm_min) * 60 + tms.tm_sec + fmod(now, 1.);
    if (isPreview)
        now = fmod(now * 6, 60 * 60 * 24);
    return now;
}

/** Return the rotation amount (between 0 and 1) that a hand would have at time `now' if it makes one rotation every `period' seconds. A rotation of 0 (or 1) is along the positive X axis.  A rotation of 1/4 is along the positive Y axis. */

static double
getRotation(double now, double period)
{
    return .25 - fmod(now, period) / period;
}

static NSRect
getRootAndRotators(BOOL isPreview, NSRect bounds, Rotator r0, Rotator r1)
{
    double now = getNow(isPreview);
    double hourRotation = getRotation(now, 12 * 60 * 60);
    double minuteRotation = getRotation(now, 60 * 60);
    double secondRotation = getRotation(now, 60);
    
    double scale = transition(now, 12.,
        61., 1.,
        61., 0.793700525984099737375852819636, // cube root of 1/2
        0.);
        
    initRotator(r0, secondRotation - hourRotation, -scale);
    initRotator(r1, minuteRotation - hourRotation, -scale);

    Rotator r;
    initRotator(r, hourRotation, 1);
    double rootSize = MIN(bounds.size.width, bounds.size.height) / 6.;
    NSRect root;
    root.size = rotateSize(r, NSMakeSize(-rootSize, 0));
    root.origin.x = NSMidX(bounds) - root.size.width;
    root.origin.y = NSMidY(bounds) - root.size.height;
    return root;
}

static void
drawBranch(NSRect* line, Rotator r0, Rotator r1, unsigned int depth, unsigned int depthLeft, float* color)
{
    NSPoint p2 = NSMakePoint(
            line->origin.x + line->size.width,
            line->origin.y + line->size.height);

    if (depthLeft >= 1) {
        NSRect newLine;
        newLine.origin = p2;
        float newColor[3];
        newColor[1] = .92 * color[1];

        newLine.size = rotateSize(r0, line->size);
        newColor[0] = ColorAdjustment * color[0];
        newColor[2] = .1 + ColorAdjustment * color[2];
        drawBranch(&newLine, r0, r1, depth + 1, depthLeft - 1, newColor);

        newLine.size = rotateSize(r1, line->size);
        newColor[0] = .1 + ColorAdjustment * color[0];
        newColor[2] = ColorAdjustment * color[2];
        drawBranch(&newLine, r0, r1, depth + 1, depthLeft - 1, newColor);
    }

    glColor4f(color[0], color[1], color[2], alphaForDepth[depth]);
    if (depth == 0) {
        glVertex2f(
            line->origin.x + line->size.width * .5,
            line->origin.y + line->size.height * .5);
    } else
        glVertex2f(line->origin.x, line->origin.y);
    glVertex2f(p2.x, p2.y);
}

@implementation FractalClockView

+ (void)initialize;
{
    alphaForDepth[0] = 1;
    for (int i = 1; i < MaxDepth; ++i)
        alphaForDepth[i] = pow(i, -1.0);
}

- (id)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self == nil)
        return nil;
        
    [self setAnimationTimeInterval:1./FramesPerSecond];
    
    return self;
}


- (void)startAnimation
{
    [super startAnimation];
        
    ++viewsCount;
    totalPixelCount += [self bounds].size.width * [self bounds].size.height;

    targetDepth = 4;
    framesBetweenDepthChanges = FramesPerSecond;
    accumulatedFrames = 0;
    accumulatedSeconds = 0;

    if (glContext != nil)
        return;

    glContext = [[NSOpenGLContext alloc] initWithFormat:[NSOpenGLView defaultPixelFormat] shareContext:nil];
    [glContext setView:self];
    
    [glContext makeCurrentContext];
    cgl_ctx = CGLGetCurrentContext();
    cgl_rend = cgl_ctx->rend;

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_LIGHTING);
    glDisable(GL_DITHER);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_ALPHA_TEST);
    glAlphaFunc(GL_GREATER, 1./255);
    
    glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
    glEnable(GL_LINE_SMOOTH);
}

- (void)stopAnimation
{
    [super stopAnimation];
    --viewsCount;
    if (viewsCount == 0)
        totalPixelCount = 0;
    else
        totalPixelCount -= [self bounds].size.width * [self bounds].size.height;
}

- (BOOL)isOpaque;
{
    return YES;
}

- (void)drawRect:(NSRect)rect
{
    if (glContext == nil) {
        // startAnimation hasn't been called yet.
        return;
    }
    [glContext makeCurrentContext];
    cgl_ctx = CGLGetCurrentContext();
    cgl_rend = cgl_ctx->rend;

    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];

    NSRect bounds = [self bounds];

    glViewport(0, 0, bounds.size.width, bounds.size.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, bounds.size.width, 0, bounds.size.height, 0, 1);
    
    glClearColor(0., 0., 0., 1.);
    glClear(GL_COLOR_BUFFER_BIT);
    
    static float rootColor[3] = { 1, 1, 1 };

    Rotator r0;
    Rotator r1;
    NSRect root = getRootAndRotators([self isPreview], bounds, r0, r1);

    glLineWidth(2.);
    glBegin(GL_LINES);
        drawBranch(&root, r0, r1, 0, targetDepth, rootColor);
    glEnd();
    glFlush();
    glFinish();
    
    accumulatedSeconds += [NSDate timeIntervalSinceReferenceDate] - startTime;
    ++accumulatedFrames;
    if (accumulatedFrames >= framesBetweenDepthChanges * viewsCount) {
        double framesPerSecond = accumulatedFrames / (viewsCount * accumulatedSeconds);
        accumulatedFrames = 0;
        accumulatedSeconds = 0;
        framesBetweenDepthChanges *= 1.0;
        
        if (framesPerSecond > 2.5*FramesPerSecond)
            ++targetDepth;
        else if (framesPerSecond < 1.5*FramesPerSecond)
            --targetDepth;
        
        double maxDepth = ceil(log2(sqrt(totalPixelCount)));
        if (targetDepth > maxDepth)
            targetDepth = maxDepth;
    }
}

- (void)animateOneFrame
{
    [self setNeedsDisplay:YES];
}

- (BOOL)hasConfigureSheet
{
    return NO;
}

- (NSWindow*)configureSheet
{
    return nil;
}

@end
