//
//  JJAVAssetExportSession.m
//
// This file is part of the JJAVAssetExportSession package.
//
// Created by Olivier Poitrey <rs@dailymotion.com> on 13/03/13.
// Copyright 2013 Olivier Poitrey. All rights servered.
//
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.
//


#import "JJAVAssetExportSession.h"
#import <AVKit/AVKit.h>
#import <CoreVideo/CVPixelBuffer.h>

@interface JJAVAssetExportSession ()

@property (nonatomic, assign, readwrite) float progress;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderVideoCompositionOutput *videoOutput;
@property (nonatomic, strong) AVAssetReaderAudioMixOutput *audioOutput;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *videoPixelBufferAdaptor;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, strong) void (^completionHandler)(void);

@end

@implementation JJAVAssetExportSession
{
    NSError *_error;
    NSTimeInterval duration;
    CMTime lastSamplePresentationTime;
}

-(instancetype)init
{
    if ((self = [super init]))
    {
        _timeRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    }
    return self;
}


- (void)exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler
{
    NSParameterAssert(handler != nil);
    [self cancelExport];
    self.completionHandler = handler;

    if (!self.outputURL)
    {
        _error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed userInfo:@
        {
            NSLocalizedDescriptionKey: @"Output URL not set"
        }];
        handler();
        return;
    }

    NSError *readerError;
    self.reader = [AVAssetReader assetReaderWithAsset:self.asset error:&readerError];
    if (readerError) {
        _error = readerError;
        handler();
        return;
    }

    NSError *writerError;
    self.writer = [AVAssetWriter assetWriterWithURL:self.outputURL fileType:self.outputFileType error:&writerError];
    if (writerError) {
        _error = writerError;
        handler();
        return;
    }

    if (CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVE_INFINITY(self.timeRange.duration))
    {
        duration = CMTimeGetSeconds(self.timeRange.duration);
    }
    else
    {
        duration = CMTimeGetSeconds(self.asset.duration);
        self.timeRange = CMTimeRangeMake(kCMTimeZero, self.asset.duration);
    }
    self.reader.timeRange = self.timeRange;
    self.writer.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse;
    AVMutableMetadataItem* zipTagItem = [AVMutableMetadataItem metadataItem];
    zipTagItem.identifier = AVMetadataCommonIdentifierDescription;
    zipTagItem.value = @"com.sean.zipTag";
    if (self.metadata) {
        NSMutableArray* metadata = self.metadata.mutableCopy;
        [metadata addObject:zipTagItem];
        self.writer.metadata = metadata;
    } else {
        self.writer.metadata = @[zipTagItem];
    }

    NSArray<AVAssetTrack* >* videoTracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    //
    // Video output
    //
    if (videoTracks.count > 0) {
        if (self.videoInputSettings) {
            self.videoOutput = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:videoTracks videoSettings:self.videoInputSettings];
        } else {
            self.videoOutput = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:videoTracks videoSettings:@{(id) kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], (id) kCVPixelBufferIOSurfacePropertiesKey: @{}, (id) kCVPixelBufferOpenGLESCompatibilityKey: @YES}];
        }
        self.videoOutput.alwaysCopiesSampleData = NO;
        if (self.videoComposition) {
            self.videoOutput.videoComposition = self.videoComposition;
        } else {
            self.videoOutput.videoComposition = [self buildDefaultVideoComposition];
        }
        if ([self.reader canAddOutput:self.videoOutput]) {
            [self.reader addOutput:self.videoOutput];
        }

        //
        // Video input
        //
        NSMutableDictionary* videoSettings = self.videoSettings.mutableCopy;
        if (videoSettings)
        {
            NSMutableDictionary *videoCompressionProperties = [[videoSettings objectForKey:AVVideoCompressionPropertiesKey] mutableCopy];
            if (videoCompressionProperties)
            {
                NSNumber *frameRate = [videoCompressionProperties objectForKey:AVVideoAverageNonDroppableFrameRateKey];
                // 去除帧数设置
                if (frameRate)
                {
                    [videoCompressionProperties removeObjectForKey:AVVideoAverageNonDroppableFrameRateKey];
                    [videoSettings setObject:videoCompressionProperties forKey:AVVideoCompressionPropertiesKey];
                }
            }
            if (self.videoOutput.videoComposition) {
                videoSettings[AVVideoHeightKey] = [NSNumber numberWithFloat:self.videoOutput.videoComposition.renderSize.height];
                videoSettings[AVVideoWidthKey] = [NSNumber numberWithFloat:self.videoOutput.videoComposition.renderSize.width];
            }
        }
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        self.videoInput.expectsMediaDataInRealTime = NO;
        if ([self.writer canAddInput:self.videoInput]) {
            [self.writer addInput:self.videoInput];
        }
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(self.videoOutput.videoComposition.renderSize.width),
            (id)kCVPixelBufferHeightKey: @(self.videoOutput.videoComposition.renderSize.height),
            @"IOSurfaceOpenGLESTextureCompatibility": @YES,
            @"IOSurfaceOpenGLESFBOCompatibility": @YES,
        };
        self.videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:pixelBufferAttributes];
    }

    //
    //Audio output
    //
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count > 0)
    {
        // 添加output到reader
        self.audioOutput = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:audioTracks audioSettings:@{AVFormatIDKey: [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM]}];
        self.audioOutput.alwaysCopiesSampleData = NO;
        self.audioOutput.audioMix = self.audioMix;
        if ([self.reader canAddOutput:self.audioOutput])
        {
            [self.reader addOutput:self.audioOutput];
        }
    }
    else
    {
        // Just in case this gets reused
        self.audioOutput = nil;
    }

    //
    // Audio input
    //
    if (self.audioOutput)
    {
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
        self.audioInput.expectsMediaDataInRealTime = NO;
        if ([self.writer canAddInput:self.audioInput])
        {
            [self.writer addInput:self.audioInput];
        }
    }
    
    [self.writer startWriting];
    [self.reader startReading];
    [self.writer startSessionAtSourceTime:self.timeRange.start];

    __block BOOL videoCompleted = NO;
    __block BOOL audioCompleted = NO;
    __weak typeof(self) wself = self;
    self.inputQueue = dispatch_queue_create("VideoEncoderInputQueue", DISPATCH_QUEUE_SERIAL);
    if (videoTracks.count > 0) {
        [self.videoInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
        {
            if (![wself encodeReadySamplesFromOutput:wself.videoOutput toInput:wself.videoInput])
            {
                @synchronized(wself)
                {
                    videoCompleted = YES;
                    if (audioCompleted)
                    {
                        [wself finish];
                    }
                }
            }
        }];
    }
    else {
        videoCompleted = YES;
    }
    
    if (!self.audioOutput)
    {
        audioCompleted = YES;
    }
    else
    {
        [self.audioInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
         {
             if (![wself encodeReadySamplesFromOutput:wself.audioOutput toInput:wself.audioInput])
             {
                 @synchronized(wself)
                 {
                     audioCompleted = YES;
                     if (videoCompleted)
                     {
                         [wself finish];
                     }
                 }
             }
         }];
    }
}

- (BOOL)encodeReadySamplesFromOutput:(AVAssetReaderOutput *)output toInput:(AVAssetWriterInput *)input
{
    while (input.isReadyForMoreMediaData)
    {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer)
        {
            BOOL handled = NO;
            BOOL error = NO;

            if (self.reader.status != AVAssetReaderStatusReading || self.writer.status != AVAssetWriterStatusWriting)
            {
                handled = YES;
                error = YES;
            }
            
            if (!handled && self.videoOutput == output)
            {
                // update the video progress
                lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                lastSamplePresentationTime = CMTimeSubtract(lastSamplePresentationTime, self.timeRange.start);
                self.progress = duration == 0 ? 1 : CMTimeGetSeconds(lastSamplePresentationTime) / duration;

                if ([self.delegate respondsToSelector:@selector(exportSession:renderFrame:withPresentationTime:toBuffer:)])
                {
                    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
                    CVPixelBufferRef renderBuffer = NULL;
                    CVPixelBufferPoolCreatePixelBuffer(NULL, self.videoPixelBufferAdaptor.pixelBufferPool, &renderBuffer);
                    [self.delegate exportSession:self renderFrame:pixelBuffer withPresentationTime:lastSamplePresentationTime toBuffer:renderBuffer];
                    if (![self.videoPixelBufferAdaptor appendPixelBuffer:renderBuffer withPresentationTime:lastSamplePresentationTime])
                    {
                        error = YES;
                    }
                    CVPixelBufferRelease(renderBuffer);
                    handled = YES;
                }
            }
            if (!handled && ![input appendSampleBuffer:sampleBuffer])
            {
                error = YES;
            }
            CFRelease(sampleBuffer);

            if (error)
            {
                return NO;
            }
        }
        else
        {
            [input markAsFinished];
            return NO;
        }
    }

    return YES;
}

- (AVMutableVideoComposition *)buildDefaultVideoComposition {
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:self.asset];
    NSArray<AVAssetTrack* >* tracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks || tracks.count == 0) {
        return videoComposition;
    }
    AVAssetTrack *videoTrack = [tracks objectAtIndex:0];

    // 帧数
    float trackFrameRate = [videoTrack nominalFrameRate];
    if (self.videoSettings) {
        NSDictionary *videoCompressionProperties = [self.videoSettings objectForKey:AVVideoCompressionPropertiesKey];
        if (videoCompressionProperties) {
            NSNumber *frameRate = [videoCompressionProperties objectForKey:AVVideoAverageNonDroppableFrameRateKey];
            // 帧数大了要变小
            if (frameRate && frameRate.floatValue < trackFrameRate) {
                trackFrameRate = frameRate.floatValue;
            }
        }
    }
    if (trackFrameRate == 0) {
        trackFrameRate = 30;
    }
    videoComposition.frameDuration = CMTimeMake(1, trackFrameRate);

    // 判断旋转
    CGSize targetSize = CGSizeMake([self.videoSettings[AVVideoWidthKey] floatValue], [self.videoSettings[AVVideoHeightKey] floatValue]);
    CGSize naturalSize = [videoTrack naturalSize];
    CGAffineTransform preferredTransform = videoTrack.preferredTransform;
    CGAffineTransform transform;
    if(preferredTransform.a == 0 && preferredTransform.b == 1.0 && preferredTransform.c == -1.0 && preferredTransform.d == 0){
        // Portrait 90
        CGFloat width = naturalSize.width;
        naturalSize.width = naturalSize.height;
        naturalSize.height = width;
        // 旋转
        CGAffineTransform translateToCenter = CGAffineTransformMakeTranslation(videoTrack.naturalSize.height, 0.0);
        transform = CGAffineTransformRotate(translateToCenter, M_PI_2);
    } else if(preferredTransform.a == 0 && preferredTransform.b == -1.0 && preferredTransform.c == 1.0 && preferredTransform.d == 0){
        // PortraitUpsideDown 270
        CGFloat width = naturalSize.width;
        naturalSize.width = naturalSize.height;
        naturalSize.height = width;
        // 旋转
        CGAffineTransform translateToCenter = CGAffineTransformMakeTranslation(0.0, videoTrack.naturalSize.width);
        transform = CGAffineTransformRotate(translateToCenter,M_PI_2*3.0);
    } else if(preferredTransform.a == -1.0 && preferredTransform.b == 0 && preferredTransform.c == 0 && preferredTransform.d == -1.0){
        // LandscapeLeft 180
        // 旋转
        CGAffineTransform translateToCenter = CGAffineTransformMakeTranslation(videoTrack.naturalSize.width, videoTrack.naturalSize.height);
        transform = CGAffineTransformRotate(translateToCenter, M_PI);
    } else {
        // LandscapeRight 0
        transform = CGAffineTransformIdentity;
    }
    NSLog(@"**** 期望视频宽：%lf，期望视频高：%lf", targetSize.width, targetSize.height);
    NSLog(@"**** 视频宽：%lf，视频高：%lf", naturalSize.width, naturalSize.height);
    if (targetSize.width < naturalSize.width || targetSize.height < naturalSize.height) {
        CGRect realRect = AVMakeRectWithAspectRatioInsideRect(CGSizeMake(naturalSize.width, naturalSize.height), CGRectMake(0, 0, targetSize.width, targetSize.height));
        videoComposition.renderSize = realRect.size;
        float xratio = realRect.size.width/naturalSize.width;
        float yratio = realRect.size.height/naturalSize.height;
        NSLog(@"**** 视频宽压缩：%lf，视频高压缩：%lf", xratio, yratio);
        CGAffineTransform matrix = CGAffineTransformMakeScale(xratio, yratio);
        // 位移
        transform = CGAffineTransformConcat(transform, matrix);
    } else {
        videoComposition.renderSize = naturalSize;
    }
    NSLog(@"**** 压缩后视频宽：%lf，压缩后视频高：%lf", videoComposition.renderSize.width, videoComposition.renderSize.height);

    AVMutableVideoCompositionInstruction *passThroughInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    passThroughInstruction.timeRange = self.timeRange;
    // 旋转、位移
    AVMutableVideoCompositionLayerInstruction *passThroughLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [passThroughLayer setTransform:transform atTime:self.timeRange.start];
    passThroughInstruction.layerInstructions = @[passThroughLayer];
    videoComposition.instructions = @[passThroughInstruction];

    return videoComposition;
}

- (void)finish
{
    // Synchronized block to ensure we never cancel the writer before calling finishWritingWithCompletionHandler
    if (self.reader.status == AVAssetReaderStatusCancelled || self.writer.status == AVAssetWriterStatusCancelled)
    {
        return;
    }

    if (self.writer.status == AVAssetWriterStatusFailed)
    {
        [self complete];
    }
    else if (self.reader.status == AVAssetReaderStatusFailed)
    {
        [self.writer cancelWriting];
        [self complete];
    }
    else
    {
        [self.writer finishWritingWithCompletionHandler:^
        {
            [self complete];
        }];
    }
}

- (void)complete
{
    if (self.writer.status == AVAssetWriterStatusFailed || self.writer.status == AVAssetWriterStatusCancelled)
    {
        [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
    }

    if (self.completionHandler)
    {
        self.completionHandler();
        self.completionHandler = nil;
    }
}

- (NSError *)error
{
    if (_error)
    {
        return _error;
    }
    else
    {
        return self.writer.error ? : self.reader.error;
    }
}

- (AVAssetExportSessionStatus)status
{
    switch (self.writer.status)
    {
        default:
        case AVAssetWriterStatusUnknown:
            return AVAssetExportSessionStatusUnknown;
        case AVAssetWriterStatusWriting:
            return AVAssetExportSessionStatusExporting;
        case AVAssetWriterStatusFailed:
            return AVAssetExportSessionStatusFailed;
        case AVAssetWriterStatusCompleted:
            return AVAssetExportSessionStatusCompleted;
        case AVAssetWriterStatusCancelled:
            return AVAssetExportSessionStatusCancelled;
    }
}

- (void)cancelExport
{
    if (self.inputQueue) {
        dispatch_async(self.inputQueue, ^ {
            [self.writer cancelWriting];
            [self.reader cancelReading];
            [self complete];
            [self reset];
        });
    }
}

- (void)cancelExportNoComplete
{
    if (self.inputQueue) {
        dispatch_async(self.inputQueue, ^ {
            [self.writer cancelWriting];
            [self.reader cancelReading];
            [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
            [self reset];
        });
    }
}

- (void)reset
{
    _error = nil;
    self.progress = 0;
    self.reader = nil;
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.writer = nil;
    self.videoInput = nil;
    self.videoPixelBufferAdaptor = nil;
    self.audioInput = nil;
    self.inputQueue = nil;
    self.completionHandler = nil;
}

@end
