//
//  CSScreenRecorder.m
//  RecordMyScreen
//
//  Created by Aditya KD on 02/04/13.
//  Copyright (c) 2013 CoolStar Organization. All rights reserved.
//

#import "CSScreenRecorder.h"

//#import <IOMobileFrameBuffer.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <QuartzCore/QuartzCore.h>

//#include <IOSurface.h>
//#include <IOSurfaceAPI.h>
//#include <IOSurfaceBase.h>
#include <sys/time.h>

//void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

@interface CSScreenRecorder ()
{
@private
    BOOL                _isCanceling;
    BOOL                _isCancelingFromNotif;

    BOOL                _isRecording;
    BOOL                _isSetup;

    int                 _kbps;
    int                 _fps;
    
    //surface
//    IOSurfaceRef        _surface;
    int                 _bytesPerRow;
    int                 _width;
    int                 _height;
    
    dispatch_queue_t    _videoQueue;
    
    NSLock             *_pixelBufferLock;
    NSTimer            *_recordingTimer;
    NSDate             *_recordStartDate;
    
    AVAudioRecorder    *_audioRecorder;
    AVAssetWriter      *_videoWriter;
    AVAssetWriterInput *_videoWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *_pixelBufferAdaptor;
}

@property(nonatomic, copy) NSString *exportPath;


- (void)_setupVideoContext;
- (void)_setupAudio;
- (void)_setupVideoAndStartRecording;
- (void)_captureShot:(CMTime)frameTime;
//- (IOSurfaceRef)_createScreenSurface;
- (void)_finishEncoding;

- (void)_sendDelegateTimeUpdate:(NSTimer *)timer;

@end

@implementation CSScreenRecorder

- (instancetype)init
{
    if ((self = [super init])) {
        _pixelBufferLock = [NSLock new];
        
        //video queue
        _videoQueue = dispatch_queue_create("video_queue", DISPATCH_QUEUE_SERIAL);
        //frame rate
        _fps = 24;
        //encoding kbps
        _kbps = 5000;
    }
    return self;
}

- (void)dealloc
{
//    if (_isSetup == YES) {
//        CFRelease(_surface);
//        _surface = NULL;
//    }
    
    dispatch_release(_videoQueue);
    _videoQueue = NULL;
    
    [_pixelBufferLock release];
    _pixelBufferLock = nil;
    
    [_recordingView release];
    _recordingView = nil;
    
    [_videoOutPath release];
    _videoOutPath = nil;
    
    _recordingTimer = nil;
    // These are released when capture stops, etc, but what if?
    // You don't want to leak memory!
    [_recordStartDate release];
    _recordStartDate = nil;
    
    [_audioRecorder release];
    _audioRecorder = nil;
    
    [_videoWriter release];
    _videoWriter = nil;
    
    [_videoWriterInput release];
    _videoWriterInput = nil;
    
    [_pixelBufferAdaptor release];
    _pixelBufferAdaptor = nil;
    
    [super dealloc];
}

- (void)startRecordingScreen
{
    
    // if the AVAssetWriter is NOT valid, setup video context
    if(!_videoWriter)
        [self _setupVideoContext]; // this must be done before _setupVideoAndStartRecording
    _recordStartDate = [[NSDate date] retain];
    
    [self _setupVideoAndStartRecording];
}

- (void)stopRecordingScreen
{
	// Set the flag to stop recording
    _isRecording = NO;
    _isCanceling = NO;

    // Invalidate the recording time
    [_recordingTimer invalidate];
    _recordingTimer = nil;
}

- (void)cancelRecordingScreen {
    // Set the flag to stop recording
    _isRecording = NO;
    _isCanceling = YES;
    // Invalidate the recording time
    [_recordingTimer invalidate];
    _recordingTimer = nil;

}

- (void)_setupAudio
{
    
    _isSetup = YES;
    
    // Setup to be able to record global sounds (preexisting app sounds)
	NSError *sessionError = nil;
    if ([[AVAudioSession sharedInstance] respondsToSelector:@selector(setCategory:withOptions:error:)])
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDuckOthers error:&sessionError];
    else
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&sessionError];
    
    // Set the audio session to be active
	[[AVAudioSession sharedInstance] setActive:YES error:&sessionError];
    
    if (sessionError && [self.delegate respondsToSelector:@selector(screenRecorder:audioSessionSetupFailedWithError:)]) {
        [self.delegate screenRecorder:self audioSessionSetupFailedWithError:sessionError];
        return;
    }
    
    // Set the number of audio channels, using defaults if necessary.
    NSNumber *audioChannels = (self.numberOfAudioChannels ? self.numberOfAudioChannels : @2);
    NSNumber *sampleRate    = (self.audioSampleRate       ? self.audioSampleRate       : @44100.f);
    
    NSDictionary *audioSettings = @{
                                    AVNumberOfChannelsKey : (audioChannels ? audioChannels : @2),
                                    AVSampleRateKey       : (sampleRate    ? sampleRate    : @44100.0f)
                                    };
    
    
    // Initialize the audio recorder
    // Set output path of the audio file
    NSError *error = nil;
    NSAssert((self.audioOutPath != nil), @"Audio out path cannot be nil!");
    _audioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.audioOutPath] settings:audioSettings error:&error];
    if (error && [self.delegate respondsToSelector:@selector(screenRecorder:audioRecorderSetupFailedWithError:)]) {
        // Let the delegate know that shit has happened.
        [self.delegate screenRecorder:self audioRecorderSetupFailedWithError:error];
        
        [_audioRecorder release];
        _audioRecorder = nil;
        
        return;
    }
    
    [_audioRecorder setDelegate:self];
    [_audioRecorder prepareToRecord];
    
    // Start recording :P
    [_audioRecorder record];
}

- (void)_setupVideoAndStartRecording
{
    
    _isSetup = YES;
    
    // Set timer to notify the delegate of time changes every second
    _recordingTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                       target:self
                                                     selector:@selector(_sendDelegateTimeUpdate:)
                                                     userInfo:nil
                                                      repeats:YES];
    
    _isRecording = YES;
    _isCanceling = NO;
    _isCancelingFromNotif = NO;
    //capture loop (In another thread)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        
        int targetFPS = _fps;
        int msBeforeNextCapture = 1000 / targetFPS;
        
        //struct timeval lastCapture, currentTime, startTime;
        //lastCapture.tv_sec = 0;
        //lastCapture.tv_usec = 0;
        
        
        
        long long lastCaptureMS, currentTimeMS, startTimeMS;
        
        lastCaptureMS = 0;
        
        //recording start time
        //gettimeofday(&startTime, NULL);
        //startTime.tv_usec /= 1000;
        
        startTimeMS = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        
        //startTimeMS = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        
        //startTimeMS = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        
        
        
        //int lastFrame = -1;
        long long lastFrame = -1;
        while(_isRecording)
        {
            
            
            //time passed since last capture
            //gettimeofday(&currentTime, NULL);
            currentTimeMS = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
            
            
            //convert to milliseconds to avoid overflows
            //currentTime.tv_usec /= 1000;
            
            //unsigned long long diff = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (lastCapture.tv_usec + (1000 * lastCapture.tv_sec) );
            unsigned long long diff = currentTimeMS - lastCaptureMS;
            
            // if enough time has passed, capture another shot
            if(diff >= msBeforeNextCapture)
            {
                //time since start
                //long int msSinceStart = (currentTime.tv_usec + (1000 * currentTime.tv_sec) ) - (startTime.tv_usec + (1000 * startTime.tv_sec) );
                long long msSinceStart = currentTimeMS - startTimeMS;
                
                // Generate the frame number
                //int frameNumber = msSinceStart / msBeforeNextCapture;
                long long frameNumber = msSinceStart / msBeforeNextCapture;
                CMTime presentTime;
                presentTime = CMTimeMake(frameNumber, targetFPS);
                
                // Frame number cannot be last frames number :P
                NSParameterAssert(frameNumber != lastFrame);
                lastFrame = frameNumber;
                
                // Capture next shot and repeat
                [self _captureShot2:presentTime];
                lastCaptureMS = currentTimeMS;
            }
             
         
        }
        
        
        
        // finish encoding, using the video_queue thread
        dispatch_async(_videoQueue, ^{
            if (!_isCanceling) {
                [self _finishEncoding];
            }
            else {
                [self _cancelEncoding];
            }
        });
         
     
        
    });
     
    
    
}

- (void)_captureShot2:(CMTime)frameTime {

    //NSDate * start = [NSDate date];
    //UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, self.window.screen.scale);
    //TODO: ADOLFO CHANGED THE SCALE TO POSSIBLY RETINA
    
    NSLog(@"current view width: %f, height: %f",self.recordingView.bounds.size.width,self.recordingView.bounds.size.height);
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        if ([UIScreen mainScreen].scale == 2.0) {
            
            //TODO: FJ CHANGED THE SCALE TO NON RETINA FOR IPAD RETINA

            
            NSLog(@"IPAD RETINA");
//            videowidth /= 2; //If it's set to half-size, divide both by 2.
//            videoheight /= 2;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(self.recordingView.bounds.size.width, self.recordingView.bounds.size.height), self.recordingView.opaque,[UIScreen mainScreen].scale);
            [self.recordingView drawViewHierarchyInRect:CGRectMake(0,0,self.recordingView.frame.size.height, self.recordingView.frame.size.width) afterScreenUpdates:NO];
            UIImage * background = UIGraphicsGetImageFromCurrentImageContext();
            self.currentScreen = background;
            UIGraphicsEndImageContext();

        }
        else {
            NSLog(@"IPAD");
            
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(self.recordingView.bounds.size.width, self.recordingView.bounds.size.height), self.recordingView.opaque,[UIScreen mainScreen].scale);
            [self.recordingView drawViewHierarchyInRect:CGRectMake(0,0,self.recordingView.frame.size.height, self.recordingView.frame.size.width) afterScreenUpdates:NO];
            UIImage * background = UIGraphicsGetImageFromCurrentImageContext();
            self.currentScreen = background;
            UIGraphicsEndImageContext();
        }
    }
    else {
        NSLog(@"IPHONE");

        UIGraphicsBeginImageContextWithOptions(CGSizeMake(self.recordingView.bounds.size.height, self.recordingView.bounds.size.width), self.recordingView.opaque,[UIScreen mainScreen].scale);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSaveGState(ctx);
        CGContextConcatCTM(ctx,CGAffineTransformConcat(CGAffineTransformMakeTranslation(-self.recordingView.bounds.size.width,0),CGAffineTransformMakeRotation(-M_PI_2)));
        [self.recordingView drawViewHierarchyInRect:CGRectMake(0,0,self.recordingView.frame.size.height, self.recordingView.frame.size.width) afterScreenUpdates:NO];
        UIImage * background = UIGraphicsGetImageFromCurrentImageContext();
        self.currentScreen = background;
        UIGraphicsEndImageContext();

    }

    
    dispatch_async(dispatch_get_main_queue(), ^{


        if (_isRecording) {
            //float millisElapsed = [[NSDate date] timeIntervalSinceDate:_recordStartDate] * 1000.0;
    //        [self writeVideoFrameAtTime:CMTimeMake((int)millisElapsed, 1000)];
            
            //CMTime time = CMTimeMake((int)millisElapsed, 1000);
            
            
            if (![_videoWriterInput isReadyForMoreMediaData]) {
    //            if (_verbose)
                    NSLog(@"Not ready for video data");
            } else {
                @synchronized (self) {
                    
                    //NSLog(@"current screen is %@", self.currentScreen);
                    UIImage* newFrame = [self.currentScreen retain];
                    CVPixelBufferRef pixelBuffer = NULL;
                    CGImageRef cgImage = CGImageCreateCopy([newFrame CGImage]);
                    CFDataRef image = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
                    
    //                int status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, avAdaptor.pixelBufferPool, &pixelBuffer);
                    int status = CVPixelBufferPoolCreatePixelBuffer (kCFAllocatorDefault, _pixelBufferAdaptor.pixelBufferPool, &pixelBuffer);

                    if(status != 0){
                        //could not get a buffer from the pool
    //                    if (_verbose)
                            NSLog(@"Error creating pixel buffer:  status=%d", status);
                    }
                    
                    // set image data into pixel buffer
                    CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
                    uint8_t* destPixels = CVPixelBufferGetBaseAddress(pixelBuffer);
                    CFDataGetBytes(image, CFRangeMake(0, CFDataGetLength(image)), destPixels);  // Note:  will work if the pixel buffer is contiguous and has the same bytesPerRow as the input data
                    
                    if(status == 0){
                        BOOL success = [_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
                        if (!success) {
    //                        if (_verbose)
                                NSLog(@"Warning:  Unable to write buffer to video");
                        }
                    }
                    
                    //clean up
                    [newFrame release];
                    CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
                    CVPixelBufferRelease( pixelBuffer );
                    CFRelease(image);
                    CGImageRelease(cgImage);
                     
                 
                }
                
            }
        }
    });
 
 

//    float processingSeconds = [[NSDate date] timeIntervalSinceDate:start];
//    float delayRemaining = (1.0 / 30.0) - processingSeconds;

    //if (_verbose)
    //   NSLog(@"1time elapsed was %f seconds & %f seconds are remaining...", processingSeconds, delayRemaining);

//    [NSThread sleepForTimeInterval:delayRemaining > 0.0 ? delayRemaining : 0.01];
    //NSLog(@"--> exiting on thread using new iOS7 screen snapshot...");
//    _snapshotThreadRunning = FALSE;

    // redraw at the specified framerate
//    [self.recordingView performSelectorOnMainThread:@selector(setNeedsDisplay) withObject:nil waitUntilDone:FALSE];

}

#define NUM_PIXELS_TO_CHECK 20

//- (void)_captureShot:(CMTime)frameTime
//{
//    // Create an IOSurfaceRef if one does not exist
//    if(!_surface) {
//        _surface = [self _createScreenSurface];
//    }
//    
//    // Lock the surface from other threads
//    static NSMutableArray * buffers = nil;
//    static dispatch_once_t onceToken;
//    dispatch_once(&onceToken, ^{
//        buffers = [[NSMutableArray alloc] init];
//    });
//    
//    IOSurfaceLock(_surface, 0, nil);
//    // Take currently displayed image from the LCD
//    CARenderServerRenderDisplay(0, CFSTR("LCD"), _surface, 0, 0);
//    // Unlock the surface
//    IOSurfaceUnlock(_surface, 0, 0);
//    
//    // Make a raw memory copy of the surface
//    void *baseAddr = IOSurfaceGetBaseAddress(_surface);
//    int totalBytes = _bytesPerRow * _height;
//    
//    //void *rawData = malloc(totalBytes);
//    //memcpy(rawData, baseAddr, totalBytes);
//    NSMutableData * rawDataObj = nil;
//    if (buffers.count == 0)
//        rawDataObj = [[NSMutableData dataWithBytes:baseAddr length:totalBytes] retain];
//    else @synchronized(buffers) {
//        rawDataObj = [buffers lastObject];
//        memcpy((void *)[rawDataObj bytes], baseAddr, totalBytes);
//        //[rawDataObj replaceBytesInRange:NSMakeRange(0, rawDataObj.length) withBytes:baseAddr length:totalBytes];
//        [buffers removeLastObject];
//    }
//    
//    
//    //Check if the snapchat is black because of notification, going background etc...
//    int numPixels = totalBytes/4;
//    
//    int increment = numPixels/NUM_PIXELS_TO_CHECK;
//    
//    BOOL failed = YES;
//    
//    for (int i=0;i<numPixels;i+=increment){
//        unsigned char* red = (unsigned char*)[rawDataObj bytes]+4*i;
//        unsigned char* green = red+1;
//        unsigned char* blue = green+1;
//        
//        if (*red>5 || *green>5 || *blue>5){
//            failed = NO;
//            break;
//        }
//    }
//    
//
//    
//    
//    dispatch_async(dispatch_get_main_queue(), ^{
//        
//        if (failed) {
//            
//            if (!_isCancelingFromNotif) {
//                if ([self.delegate respondsToSelector:@selector(screenRecorderDidCancelFromNotifRecording:)]) {
//                    [self.delegate screenRecorderDidCancelFromNotifRecording:self];
//                }
//                _isCancelingFromNotif = YES;
//            }
//
//            
//            return;
//        }
//        
//        if(!_pixelBufferAdaptor.pixelBufferPool){
//            NSLog(@"skipping frame: %lld", frameTime.value);
//            //free(rawData);
//            @synchronized(buffers) {
//                //[buffers addObject:rawDataObj];
//            }
//            return;
//        }
//        
//        static CVPixelBufferRef pixelBuffer = NULL;
//        
//        static dispatch_once_t onceToken;
//        dispatch_once(&onceToken, ^{
//            NSParameterAssert(_pixelBufferAdaptor.pixelBufferPool != NULL);
//            [_pixelBufferLock lock];
//            CVPixelBufferPoolCreatePixelBuffer (kCFAllocatorDefault, _pixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
//            [_pixelBufferLock unlock];
//            NSParameterAssert(pixelBuffer != NULL);
//        });
//        
//        //unlock pixel buffer data
//        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
//        void *pixelData = CVPixelBufferGetBaseAddress(pixelBuffer);
//        NSParameterAssert(pixelData != NULL);
//        
//        //copy over raw image data and free
//        memcpy(pixelData, [rawDataObj bytes], totalBytes);
//        //free(rawData);
//        @synchronized(buffers) {
//            [buffers addObject:rawDataObj];
//        }
//        
//        //unlock pixel buffer data
//        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
//        
//        dispatch_async(_videoQueue, ^{
//            // Wait until AVAssetWriterInput is ready
//            while(!_videoWriterInput.readyForMoreMediaData)
//                usleep(1000);
//            
//            // Lock from other threads
//            [_pixelBufferLock lock];
//            // Add the new frame to the video
//            [_pixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
//            
//            // Unlock
//            //CVPixelBufferRelease(pixelBuffer);
//            [_pixelBufferLock unlock];
//        });
//    });
//}

//- (IOSurfaceRef)_createScreenSurface
//{
//    // Pixel format for Alpha Red Green Blue
//    unsigned pixelFormat = 0x42475241;//'ARGB';
//    
//    // 4 Bytes per pixel
//    int bytesPerElement = 4;
//    
//    // Bytes per row
//    _bytesPerRow = (bytesPerElement * _width);
//    
//    // Properties include: SurfaceIsGlobal, BytesPerElement, BytesPerRow, SurfaceWidth, SurfaceHeight, PixelFormat, SurfaceAllocSize (space for the entire surface)
//    NSDictionary *properties = [NSDictionary dictionaryWithObjectsAndKeys:
//                                [NSNumber numberWithBool:YES], kIOSurfaceIsGlobal,
//                                [NSNumber numberWithInt:bytesPerElement], kIOSurfaceBytesPerElement,
//                                [NSNumber numberWithInt:_bytesPerRow], kIOSurfaceBytesPerRow,
//                                [NSNumber numberWithInt:_width], kIOSurfaceWidth,
//                                [NSNumber numberWithInt:_height], kIOSurfaceHeight,
//                                [NSNumber numberWithUnsignedInt:pixelFormat], kIOSurfacePixelFormat,
//                                [NSNumber numberWithInt:_bytesPerRow * _height], kIOSurfaceAllocSize,
//                                nil];
//    
//    // This is the current surface
//    return IOSurfaceCreate((CFDictionaryRef)properties);
//}

#pragma mark - Encoding
- (void)_setupVideoContext
{
    // Get the screen rect and scale
    CGRect screenRect = [UIScreen mainScreen].bounds;
    float scale = [UIScreen mainScreen].scale;
    
    // setup the width and height of the framebuffer for the device
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        // iPhone frame buffer is Portrait
        _width = screenRect.size.width * scale;
        _height = screenRect.size.height * scale;
    } else {
        // iPad frame buffer is Landscape
        _width = screenRect.size.height * scale;
        _height = screenRect.size.width * scale;
    }
    
    NSAssert((self.videoOutPath != nil) , @"A valid videoOutPath must be set before the recording starts!");
    
    NSError *error = nil;
    
    // Setup AVAssetWriter with the output path
    _videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:self.videoOutPath]
                                             fileType:AVFileTypeMPEG4
                                                error:&error];
    // check for errors
    if(error) {
        if ([self.delegate respondsToSelector:@selector(screenRecorder:videoContextSetupFailedWithError:)]) {
            [self.delegate screenRecorder:self videoContextSetupFailedWithError:error];
        }
    }
    
    // Makes sure AVAssetWriter is valid (check check check)
    NSParameterAssert(_videoWriter);
    
    // Setup AverageBitRate, FrameInterval, and ProfileLevel (Compression Properties)
    NSMutableDictionary * compressionProperties = [NSMutableDictionary dictionary];
    [compressionProperties setObject: [NSNumber numberWithInt: _kbps * 1000] forKey: AVVideoAverageBitRateKey];
    [compressionProperties setObject: [NSNumber numberWithInt: _fps] forKey: AVVideoMaxKeyFrameIntervalKey];
    [compressionProperties setObject: AVVideoProfileLevelH264Main41 forKey: AVVideoProfileLevelKey];
    
    // Setup output settings, Codec, Width, Height, Compression
    int videowidth = _width;
    int videoheight = _height;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        if ([UIScreen mainScreen].scale == 2.0) {
            NSLog(@"IPAD RETINA");
            videowidth /= 2; //If it's set to half-size, divide both by 2.
            videoheight /= 2;
        }
    }
//    else {
//        if ([[UIScreen mainScreen] bounds].size.height == 480) {
//            NSLog(@"IPHONE 4S");
//
//            videowidth /= 2; //If it's set to half-size, divide both by 2.
//            videoheight /= 2;
//        }
//    }
    NSMutableDictionary *outputSettings = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           AVVideoCodecH264, AVVideoCodecKey,
                                           [NSNumber numberWithInt:videowidth], AVVideoWidthKey,
                                           [NSNumber numberWithInt:videoheight], AVVideoHeightKey,
                                           compressionProperties, AVVideoCompressionPropertiesKey,
                                           nil];
    
    NSParameterAssert([_videoWriter canApplyOutputSettings:outputSettings forMediaType:AVMediaTypeVideo]);
    
    // Get a AVAssetWriterInput
    // Add the output settings
    _videoWriterInput = [[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                            outputSettings:outputSettings] retain];
	
    // Check if AVAssetWriter will take an AVAssetWriterInput
    NSParameterAssert(_videoWriterInput);
    NSParameterAssert([_videoWriter canAddInput:_videoWriterInput]);
    [_videoWriter addInput:_videoWriterInput];
    
    // Setup buffer attributes, PixelFormatType, PixelBufferWidth, PixelBufferHeight, PixelBufferMemoryAlocator
    NSDictionary *bufferAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                      [NSNumber numberWithInt:_width], kCVPixelBufferWidthKey,
                                      [NSNumber numberWithInt:_height], kCVPixelBufferHeightKey,
                                      kCFAllocatorDefault, kCVPixelBufferMemoryAllocatorKey,
                                      nil];
    
    // Get AVAssetWriterInputPixelBufferAdaptor with the buffer attributes
    _pixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
                                                                                           sourcePixelBufferAttributes:bufferAttributes];
    [_pixelBufferAdaptor retain];
    
    //FPS
    _videoWriterInput.mediaTimeScale = _fps;
    _videoWriter.movieTimeScale = _fps;
    
    //Start a session:
    [_videoWriterInput setExpectsMediaDataInRealTime:YES];
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:kCMTimeZero];
    
    NSParameterAssert(_pixelBufferAdaptor.pixelBufferPool != NULL);
}


- (void)_finishEncoding
{
	// Tell the AVAssetWriterInput were done appending buffers
    [_videoWriterInput markAsFinished];
    
    // Tell the AVAssetWriter to finish and close the file
    [_videoWriter finishWriting];
    
    // Make objects go away
    [_videoWriter release];
    [_videoWriterInput release];
    [_pixelBufferAdaptor release];
    _videoWriter = nil;
    _videoWriterInput = nil;
    _pixelBufferAdaptor = nil;
	
	// Stop the audio recording
    [_audioRecorder stop];
    [_audioRecorder release];
    _audioRecorder = nil;
    
    [_recordStartDate release];
    _recordStartDate = nil;
	
	[self addAudioTrackToRecording];
}

- (void)_cancelEncoding
{
	// Tell the AVAssetWriterInput were done appending buffers
    [_videoWriterInput markAsFinished];
    
    // Tell the AVAssetWriter to finish and close the file
    [_videoWriter finishWriting];
    
    // Make objects go away
    [_videoWriter release];
    [_videoWriterInput release];
    [_pixelBufferAdaptor release];
    _videoWriter = nil;
    _videoWriterInput = nil;
    _pixelBufferAdaptor = nil;
	
	// Stop the audio recording
    [_audioRecorder stop];
    [_audioRecorder release];
    _audioRecorder = nil;
    
    [_recordStartDate release];
    _recordStartDate = nil;
	
    [[NSFileManager defaultManager] removeItemAtPath:self.videoOutPath error:nil];
    
    _isCanceling = NO;
    _isCancelingFromNotif = NO;
}

- (void)addAudioTrackToRecording {
	double degrees = 0;
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        degrees = 90;
    }
    else {
        degrees = 0;
    }
    
	NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    //	if ([prefs objectForKey:@"vidorientation"])
    //		degrees = [[prefs objectForKey:@"vidorientation"] doubleValue];
	
	NSString *videoPath = self.videoOutPath;
	NSString *audioPath = self.audioOutPath;
	
    NSLog(@"audioPath %@", self.audioOutPath);
    NSLog(@"videoPath %@", self.videoOutPath);

	NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
	NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
	
	AVURLAsset *videoAsset = [[AVURLAsset alloc] initWithURL:videoURL options:nil];
	AVURLAsset *audioAsset = [[AVURLAsset alloc] initWithURL:audioURL options:nil];
	
	AVAssetTrack *assetVideoTrack = nil;
	AVAssetTrack *assetAudioTrack = nil;
	
	if ([[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
		NSArray *assetArray = [videoAsset tracksWithMediaType:AVMediaTypeVideo];
		if ([assetArray count] > 0)
			assetVideoTrack = assetArray[0];
	}
	
    //	if ([[NSFileManager defaultManager] fileExistsAtPath:audioPath] && [prefs boolForKey:@"recordaudio"]) {
    NSArray *assetArray = [audioAsset tracksWithMediaType:AVMediaTypeAudio];
    if ([assetArray count] > 0)
        assetAudioTrack = assetArray[0];
    //	}
	
	AVMutableComposition *mixComposition = [AVMutableComposition composition];
	
    //	if (assetVideoTrack != nil) {
    //		AVMutableCompositionTrack *compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    //		[compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:assetVideoTrack atTime:kCMTimeZero error:nil];
    //		if (assetAudioTrack != nil) [compositionVideoTrack scaleTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) toDuration:audioAsset.duration];
    //		[compositionVideoTrack setPreferredTransform:CGAffineTransformMakeRotation(degreesToRadians(degrees))];
    //	}
    //
    //	if (assetAudioTrack != nil) {
    //		AVMutableCompositionTrack *compositionAudioTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    //		[compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioAsset.duration) ofTrack:assetAudioTrack atTime:kCMTimeZero error:nil];
    //	}
    
    AVMutableCompositionTrack *compositionAudioTrack = nil;
    AVMutableCompositionTrack *compositionVideoTrack = nil;

    if (assetVideoTrack != nil) {
		compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
		[compositionVideoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:assetVideoTrack atTime:kCMTimeZero error:nil];
        //		if (assetAudioTrack != nil) [compositionVideoTrack scaleTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) toDuration:audioAsset.duration];
		[compositionVideoTrack setPreferredTransform:CGAffineTransformMakeRotation(degreesToRadians(degrees))];
	}
	
	if (assetAudioTrack != nil) {
		compositionAudioTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
		[compositionAudioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.duration) ofTrack:assetAudioTrack atTime:kCMTimeZero error:nil];
	}
    
    
    
    
    float duration = CMTimeGetSeconds(videoAsset.duration);
    AVMutableAudioMix *exportAudioMix = [AVMutableAudioMix audioMix];
    AVMutableAudioMixInputParameters *exportAudioMixInputParameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:compositionAudioTrack];
    [exportAudioMixInputParameters setVolumeRampFromStartVolume:1 toEndVolume:0 timeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(duration - 3, 1), CMTimeSubtract(CMTimeMakeWithSeconds(duration, 1), CMTimeMakeWithSeconds(duration - 3, 1)))];
    [exportAudioMixInputParameters setVolumeRampFromStartVolume:0 toEndVolume:1 timeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(0, 1), CMTimeSubtract(CMTimeMakeWithSeconds(3, 1), CMTimeMakeWithSeconds(0, 1)))];
    
    
    NSArray *audioMixParameters = @[exportAudioMixInputParameters];
    exportAudioMix.inputParameters = audioMixParameters;
    
    AVMutableVideoComposition* videoComposition = nil;
    //CROP THE VIDEO FOR IPHONE 4
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && [UIScreen mainScreen].bounds.size.height == 480.0) {
        
        AVMutableVideoCompositionLayerInstruction* transformer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTrack];
        
        CGAffineTransform Concat2 = CGAffineTransformConcat(compositionVideoTrack.preferredTransform, CGAffineTransformMakeTranslation(960, -50));
        [transformer setTransform:Concat2 atTime:kCMTimeZero];
        
        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeMake(kCMTimeZero, videoAsset.duration);
        instruction.layerInstructions = [NSArray arrayWithObject:transformer];
        
        videoComposition = [AVMutableVideoComposition videoComposition];
        videoComposition.renderSize = CGSizeMake(960, 540);
        videoComposition.frameDuration = CMTimeMake(1, 30);
        videoComposition.instructions = [NSArray arrayWithObject: instruction];
    }
    else if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        AVMutableVideoCompositionLayerInstruction* transformer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:compositionVideoTrack];
        
        CGAffineTransform Concat2 = CGAffineTransformConcat(compositionVideoTrack.preferredTransform, CGAffineTransformMakeTranslation(0, -96));
        [transformer setTransform:Concat2 atTime:kCMTimeZero];
//        [transformer setTransform:compositionVideoTrack.preferredTransform atTime:kCMTimeZero];

        AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
        instruction.timeRange = CMTimeRangeMake(kCMTimeZero, videoAsset.duration);
        instruction.layerInstructions = [NSArray arrayWithObject:transformer];
        
        videoComposition = [AVMutableVideoComposition videoComposition];
        videoComposition.renderSize = CGSizeMake(1024, 576);
        videoComposition.frameDuration = CMTimeMake(1, 30);
        videoComposition.instructions = [NSArray arrayWithObject: instruction];
    }
    
    
	self.exportPath = [videoPath substringWithRange:NSMakeRange(0, videoPath.length - 4)];
	self.exportPath = [NSString stringWithFormat:@"%@.mov", self.exportPath];
	NSURL *exportURL = [NSURL fileURLWithPath:self.exportPath];
	
	AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:mixComposition presetName:AVAssetExportPresetHighestQuality];
	[exportSession setOutputFileType:AVFileTypeMPEG4];
	[exportSession setOutputURL:exportURL];
	[exportSession setShouldOptimizeForNetworkUse:NO];
    [exportSession setAudioMix:exportAudioMix];
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && [UIScreen mainScreen].bounds.size.height == 480.0)) {
        [exportSession setVideoComposition:videoComposition];
    }
	
	[exportSession exportAsynchronouslyWithCompletionHandler:^(void){
		switch (exportSession.status) {
			case AVAssetExportSessionStatusCompleted:{
				[[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
				[[NSFileManager defaultManager] removeItemAtPath:audioPath error:nil];
                [videoAsset release];
                [audioAsset release];
				break;
			}
				
			case AVAssetExportSessionStatusFailed:
                [videoAsset release];
                [audioAsset release];
				NSLog(@"Failed: %@", exportSession.error);
				break;
				
			case AVAssetExportSessionStatusCancelled:
                [videoAsset release];
                [audioAsset release];
				NSLog(@"Canceled: %@", exportSession.error);
				break;
				
			default:
                [videoAsset release];
                [audioAsset release];
				break;
		}
		
        _isSetup = NO;
        
		if ([self.delegate respondsToSelector:@selector(screenRecorderDidStopRecording:)]) {
			[self.delegate screenRecorderDidStopRecording:self];
		}
	}];
}


#pragma mark - Delegate Stuff
- (void)_sendDelegateTimeUpdate:(NSTimer *)timer
{
    if ([self.delegate respondsToSelector:@selector(screenRecorder:recordingTimeChanged:)]) {
        NSTimeInterval timeInterval = [[NSDate date] timeIntervalSinceDate:_recordStartDate];
        [self.delegate screenRecorder:self recordingTimeChanged:timeInterval];
    }
}

@end
