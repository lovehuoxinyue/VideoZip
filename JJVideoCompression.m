//
//  JJVideoCompression.m
//  JJVideoManager
//
//  Created by lujunjie on 2019/3/27.
//  Copyright © 2019 JJ. All rights reserved.
//

#import "JJVideoCompression.h"
#import <UIKit/UIKit.h>

@interface JJVideoCompression()

@property (nonatomic,assign) NSInteger width;
@property (nonatomic,assign) NSInteger height;

@end

@implementation JJVideoCompression

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _audioConfigurations.samplerate = JJAudioSampleRate_11025Hz;
        _audioConfigurations.bitrate = JJAudioBitRate_32Kbps;
        _audioConfigurations.numOfChannels = 2;
        _audioConfigurations.frameSize = 8;
        
        _videoConfigurations.fps = 30;
        _videoConfigurations.videoBitRate = JJ_VIDEO_BITRATE_SUPER_HIGH;
        _videoConfigurations.videoResolution =  JJ_VIDEO_RESOLUTION_SUPER_HIGH;
    }
    return self;
}

- (void)startCompressionWithCompletionHandler:(void (^)(JJVideoCompressionState State))handler {
    NSParameterAssert(handler != nil);
    NSParameterAssert(self.inputURL != nil);
    NSParameterAssert(self.exportURL != nil);
    
    AVURLAsset *avAsset = [AVURLAsset URLAssetWithURL:self.inputURL options:nil];
    AVAssetTrack *videoTrack = [[avAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    
    self.asset = avAsset;
    self.outputURL = self.exportURL;
    self.outputFileType = AVFileTypeMPEG4;
    self.shouldOptimizeForNetworkUse = YES;
    
    float videoBitRate = [videoTrack estimatedDataRate];
    float configurationsBitRate = [self getVideoConfigurationsBitRate: videoTrack];
    
    NSMutableDictionary *videoParameter = [NSMutableDictionary dictionary];
    if (@available(iOS 11.0, *)) {
        [videoParameter setObject:AVVideoCodecTypeH264 forKey:AVVideoCodecKey];
    } else {
        [videoParameter setObject:AVVideoCodecH264 forKey:AVVideoCodecKey];
    }
    [videoParameter setObject:@(self.height) forKey:AVVideoHeightKey];
    [videoParameter setObject:@(self.width) forKey:AVVideoWidthKey];
    
    NSMutableDictionary *propertiesParameter = [NSMutableDictionary dictionary];
    [propertiesParameter setObject:@(self.videoConfigurations.fps) forKey:AVVideoAverageNonDroppableFrameRateKey];
    [propertiesParameter setObject:AVVideoProfileLevelH264HighAutoLevel forKey:AVVideoProfileLevelKey];
    if (videoBitRate > configurationsBitRate) {
        [propertiesParameter setObject:@(configurationsBitRate) forKey:AVVideoAverageBitRateKey];
    } else {
        [propertiesParameter setObject:@(videoBitRate) forKey:AVVideoAverageBitRateKey];
    }
    [videoParameter setObject:propertiesParameter forKey:AVVideoCompressionPropertiesKey];
    self.videoSettings = videoParameter;
    
    NSMutableDictionary *audioParameter = [NSMutableDictionary dictionary];
    [audioParameter setObject:@(kAudioFormatMPEG4AAC) forKey:AVFormatIDKey];
    [audioParameter setObject:@(self.audioConfigurations.numOfChannels) forKey:AVNumberOfChannelsKey];
    [audioParameter setObject:@(self.audioConfigurations.samplerate) forKey:AVSampleRateKey];
    NSInteger bitrate = self.audioConfigurations.bitrate;
    [audioParameter setObject:@(bitrate) forKey:AVEncoderBitRateKey];
    self.audioSettings = audioParameter;
    
    [self exportAsynchronouslyWithCompletionHandler:^{
        if ([self status] == AVAssetExportSessionStatusCompleted) {
            handler(JJ_VIDEO_STATE_SUCCESS);
        } else {
            handler(JJ_VIDEO_STATE_FAILURE);
        }
        [self cancelExport];
    }];
}


- (float)getVideoConfigurationsBitRate:(AVAssetTrack *)videoTrack;
{
    float bitRate = 0;
    switch (self.videoConfigurations.videoResolution)
    {
        case JJ_VIDEO_RESOLUTION_HIGH:
            self.height = 640;
            self.width = 360;
            break;
        case JJ_VIDEO_RESOLUTION_SUPER:
            self.height = 960;
            self.width = 540;
            break;
        case JJ_VIDEO_RESOLUTION_SUPER_HIGH:
            self.height = 1280;
            self.width = 720;
            break;
        default:
            break;
    }
    //矫正画布大小
    CGSize naturalSize = [videoTrack naturalSize];
    CGAffineTransform transform = videoTrack.preferredTransform;
    CGFloat videoAngleInDegree  = atan2(transform.b, transform.a) * 180 / M_PI;
    //旋转了
    if (videoAngleInDegree == 90 || videoAngleInDegree == -90)
    {
        CGFloat width = naturalSize.width;
        naturalSize.width = naturalSize.height;
        naturalSize.height = width;
    }
    if (naturalSize.width > naturalSize.height)
    {
        //横屏
        CGFloat width = self.width;
        self.width = self.height;
        self.height = width;
    }
    
    switch (self.videoConfigurations.videoBitRate)
    {
        case JJ_VIDEO_BITRATE_HIGH:
            bitRate = 896000;
            break;
        case JJ_VIDEO_BITRATE_SUPER:
            bitRate = 1800000;
            break;
        case JJ_VIDEO_BITRATE_SUPER_HIGH:
            bitRate = 3000000;
            break;
        default:
            break;
    }
    return bitRate;
}

// MARK: - 视频压缩

static NSArray<JJVideoCompression* >* zipCompressions;

/// 快速开始视频压缩
+ (void)zipWithURL:(NSString* )url timeRange:(CMTimeRange)timeRange toURL:(NSString* )toURL compalationHandle:(void(^)(NSString*))compalationHandle {
    [[NSFileManager defaultManager] removeItemAtPath:toURL error:nil];

    JJVideoCompression* compression = [JJVideoCompression new];

    JJAudioConfigurations audioConfigurations;
    audioConfigurations.samplerate = JJAudioSampleRate_16000Hz;
    audioConfigurations.bitrate = JJAudioBitRate_32Kbps;
    audioConfigurations.numOfChannels = 2;
    audioConfigurations.frameSize = 16;
    compression.audioConfigurations = audioConfigurations;

    JJVideoResolution videoResolution;
    JJVideoBitRate videoBitRate;
    NSDictionary* fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:url error:nil];
    if (fileInfo) {
        float size = [fileInfo[NSFileSize] floatValue];
        float fileSize = size/1000000.0;
        if (fileSize > 300) {
            // 大文件压缩
            videoResolution = JJ_VIDEO_RESOLUTION_HIGH;
            videoBitRate = JJ_VIDEO_BITRATE_HIGH;
        } else if (fileSize > 100) {
            // 中文件压缩
            videoResolution = JJ_VIDEO_RESOLUTION_SUPER;
            videoBitRate = JJ_VIDEO_BITRATE_SUPER;
        } else {
            // 小文件压缩
            videoResolution = JJ_VIDEO_RESOLUTION_SUPER_HIGH;
            videoBitRate = JJ_VIDEO_BITRATE_SUPER_HIGH;
        }
    } else {
        // 默认文件压缩
        videoResolution = JJ_VIDEO_RESOLUTION_SUPER_HIGH;
        videoBitRate = JJ_VIDEO_BITRATE_SUPER_HIGH;
        NSLog(@"文件压缩前：??M");
    }
    JJVideoConfigurations videoConfigurations;
    videoConfigurations.fps = 30;
    videoConfigurations.videoBitRate = videoBitRate;
    videoConfigurations.videoResolution = videoResolution;

    compression.videoConfigurations = videoConfigurations;
    compression.inputURL = [NSURL fileURLWithPath:url];
    compression.exportURL = [NSURL fileURLWithPath:toURL];
    if (CMTimeGetSeconds(timeRange.duration) > 0) {
        compression.timeRange = timeRange;
    }

    //    NotificationCenter.default.post(name: WTVideoExport.zipProgressNotification, object: zipInfo.identify, userInfo: ["progress": 0])
    //    self.compression?.rx.observeWeakly(Float.self, "progress").observe(on: MainScheduler.instance).subscribe(onNext: { (progress) in
    //        if let progress = progress {
    //            NotificationCenter.default.post(name: WTVideoExport.zipProgressNotification, object: zipInfo.identify, userInfo: ["progress": progress])
    //        }
    //            }).disposed(by: self.progressDisposeBag)

    NSMutableArray* compressions = zipCompressions ? zipCompressions.mutableCopy:[NSMutableArray arrayWithCapacity:0];
    [compressions addObject:compression];
    zipCompressions = compressions;
    [compression startCompressionWithCompletionHandler:^(JJVideoCompressionState State) {
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (State) {
                case JJ_VIDEO_STATE_SUCCESS:
                    //                    NotificationCenter.default.post(name: WTVideoExport.zipProgressNotification, object: zipInfo.identify, userInfo: ["progress": 1])
                    if (ISPRODUCT) {
                        NSDictionary* fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:toURL error:nil];
                        if (fileInfo) {
                            float size = [fileInfo[NSFileSize] floatValue];
                            float fileSize = size/1000000.0;
                            NSLog(@"文件压缩后：%fM", fileSize);
                        }
                    }
                    compalationHandle(toURL);
                    break;
                case JJ_VIDEO_STATE_FAILURE:
                    NSLog(@"文件压缩失败");
                    [[NSFileManager defaultManager] removeItemAtPath:toURL error:nil];
                    compalationHandle(nil);
                    break;
            }
            NSMutableArray* compressions = zipCompressions ? zipCompressions.mutableCopy:[NSMutableArray arrayWithCapacity:0];
            [compressions removeObject:compression];
            zipCompressions = compressions;
        });
    }];
}


@end
