//
//  FOOMMonitor.mm
//  libOOMDetector
//
//  Tencent is pleased to support the open source community by making OOMDetector available.
//  Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
//  Licensed under the MIT License (the "License"); you may not use this file except
//  in compliance with the License. You may obtain a copy of the License at
//
//  http://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
//


#import "FOOMMonitor.h"
#import "HighSpeedLogger.h"
#import <malloc/malloc.h>
#import "fishhook.h"
#import "QQLeakFileUploadCenter.h"
#import "OOMDetector.h"
#import "OOMDetectorLogger.h"
#import <mach/mach.h>
#import "NSObject+FOOMSwizzle.h"

// 要求 ARC 编译
#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

//#undef DEBUG
// 定义 crash 类型值，为啥不用 enum
#define no_crash 0
#define normal_crash 1
#define deadlock_crash 2
#define foom_crash 3

// 定义 mmap 虚拟内存的大小 10 页内存页
#define foom_mmap_size 160*1024

static FOOMMonitor* monitor;

#pragma mark - 分别用于 hook exit 和 _exit 函数，主要是监听退出状态

static void (*_orig_exit)(int);
static void (*orig_exit)(int);

void my_exit(int value)
{
    [[FOOMMonitor getInstance] appExit];
    orig_exit(value);
}

void _my_exit(int value)
{
    [[FOOMMonitor getInstance] appExit];
    _orig_exit(value);
}

// app 当前运行状态，前台、后台、终止
typedef enum{
    APPENTERBACKGROUND, //!< 后台
    APPENTERFORGROUND, //!< 前台
    APPDIDTERMINATE //!< 终止状态，这里监听的是 appdelegate 中的 terminate，注意和 isExit 区分
}App_State;

#pragma mark - UIViewController 分类，目的是hook viewDidAppear 生命周期
@interface UIViewController(FOOM)

- (void)foom_viewDidAppear:(BOOL)animated;

@end

@implementation UIViewController(FOOM)

/// ViewController viewDidAppear 的 hook, 处理非 （UIxxx 、_xxx 以及 Nav 类）类型的 VC 类。
/// @param animated 是否动画
- (void)foom_viewDidAppear:(BOOL)animated
{
    // 调用 origin viewDidAppear
    [self foom_viewDidAppear:animated];
    
    // 获取类名
    NSString *name = NSStringFromClass([self class]);
    if(
#ifdef build_for_QQ
       ![name hasPrefix:@"QUI"] &&
#endif
       ![name hasPrefix:@"_"] && ![name hasPrefix:@"UI"] && ![self isKindOfClass:[UINavigationController class]])
    {
        [[FOOMMonitor getInstance] updateStage:name];
    }
}

@end

@interface FOOMMonitor()
{
    NSString *_uuid;
    NSThread *_thread; //!< 任务执行子线程
    NSTimer *_timer; //!< 子线程添加的 runloop 任务
    NSUInteger _memWarningTimes;
    NSUInteger _residentMemSize; //!< 常驻内存大小，或缺是
    App_State _appState; //!< 记录 app 当前状态， 前台、后台或者终止
    HighSpeedLogger *_foomLogger; //!< mmap log 对象
    BOOL _isCrashed; //!< 记录是否 crash 崩溃
    BOOL _isDeadLock; //!< 记录是否死锁
    BOOL _isExit; //!< 记录是否退出状态。该退出指的是执行 exit / _exit 杀掉进程
    NSDictionary *_deadLockStack; //!< 死锁堆栈 map
    NSString *_systemVersion;
    NSString *_appVersion; //!< app version 版本号， demo 里是给的字符串，不是数组版本号。
    NSTimeInterval _ocurTime; //!< 记录上次内存读取时间
    NSTimeInterval _startTime; //!< FOOM 开启运行时间
    NSRecursiveLock *_logLock; //!< 打印的锁对象
    NSString *_currentLogPath;
    BOOL _isDetectorStarted; //!< 监控开启状态
    BOOL _isOOMDetectorOpen;
    NSString *_crash_stage; //!< 记录当前 crash 的标识符， 这里用的是 VC 的类名。 _updateStage中处理。
}

@end

@implementation FOOMMonitor

+(FOOMMonitor *)getInstance
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        monitor = [FOOMMonitor new];
    });
    return monitor;
}

-(id)init{
    if(self = [super init]){
        _uuid = [self uuid];
        _logLock = [NSRecursiveLock new];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        [_thread setName:@"foomMonitor"];
        _timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(updateMemory) userInfo:nil repeats:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [_thread start];
    }
    return self;
}

-(void)createmmapLogger
{
    [_logLock lock];
    [self hookExitAndAbort];
    
    // hook vc 的 viewDidAppear
    [self swizzleMethods];
    NSString *dir = [self foomMemoryDir];
    _systemVersion = [[NSProcessInfo processInfo] operatingSystemVersionString];
    _currentLogPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.oom",_uuid]];
    _foomLogger = new HighSpeedLogger(malloc_default_zone(), _currentLogPath, foom_mmap_size);
    _crash_stage = @" ";
    int32_t length = 0;
    if(_foomLogger && _foomLogger->isValid()){
        _foomLogger->memcpyLogger((const char *)&length, 4);
    }
    [self updateFoomData];
    [self uploadLastData];
    [_logLock unlock];
}

-(NSString *)uuid
{
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef strUuid = CFUUIDCreateString(kCFAllocatorDefault,uuid);
    NSString * str = [NSString stringWithString:(__bridge NSString *)strUuid];
    CFRelease(strUuid);
    CFRelease(uuid);
    return str;
}

-(NSString *)getLogUUID
{
    return _uuid;
}

-(NSString *)getLogPath {
    return _currentLogPath;
}

/// 开启 FOOM 检测
-(void)start
{
    // 重置状态值
    
    // 赋值开启状态
    _isDetectorStarted = YES;
    
    // 设置当前 app 状态，
    if([UIApplication sharedApplication].applicationState == UIApplicationStateBackground)
    {
        _appState = APPENTERBACKGROUND;
    }
    else {
        _appState = APPENTERFORGROUND;
    }
    
    _isCrashed = NO;
    _isExit = NO;
    _isDeadLock = NO;
    _ocurTime = [[NSDate date] timeIntervalSince1970];
    _startTime = _ocurTime;
    
    // 通过 SDK 内部的子线程创建文件和虚拟内存的映射（mmap）
    [self performSelector:@selector(createmmapLogger) onThread:_thread withObject:nil waitUntilDone:NO];
}

/// 通过 fishhook hook 系统的_exit 和 exit 退出函数
-(void)hookExitAndAbort
{
    rebind_symbols((struct rebinding[2]){{"_exit", (void *)_my_exit, (void **)&_orig_exit}, {"exit", (void *)my_exit, (void **)&orig_exit}}, 2);
}

-(void)swizzleMethods
{
    // hook ViewController 的 viewDidAppear
    [UIViewController swizzleMethod:@selector(viewDidAppear:) withMethod:@selector(foom_viewDidAppear:)];
}


-(void)threadMain
{
    // 开启子线程的 runloop
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop currentRunLoop] run];
    [_timer fire];
}

/// 更新常驻内存 resident 类型的值
-(void)updateMemory
{
    [_logLock lock];
    if(_appState == APPENTERFORGROUND)
    {
        // 通过 task 获取常驻物理内存的大小
        NSUInteger memSize = (NSUInteger)[self appResidentMemory];
        // 判断是否死锁
        if(_isDeadLock)
        {
            // 死锁状态下，和上次的 resident 内存绝对差值在 5MB 以内，没影响则直接忽略
            if(abs((int)(_residentMemSize - memSize)) < 5)
            {
                //卡死状态下内存无明显变化就不update了，避免CPU过高发热
                [_logLock unlock];
                return ;
            }
        }
        
        // 更新最新的 resident 的值
        _residentMemSize = memSize;
    }
    
    // 记录上次更新时间
    _ocurTime = [[NSDate date] timeIntervalSince1970];
    [self updateFoomData];
    [_logLock unlock];
}

/// 更新日志数据到虚拟内存中。清理上次缓存
-(void)updateFoomData{
    if(_foomLogger && _foomLogger->isValid())
    {
        // 常驻虚拟内存的大小，获取的是 resident 的值。
        NSString* residentMemory = [NSString stringWithFormat:@"%lu", (unsigned long)_residentMemSize];
        
        /**
         上报信息：
         {
            "lastMemory" : residentSize, 内存常驻大小
            "memWarning" : _memWarningTimes, 内存告警时间
            "uuid" :,
            "systemVersion" : ,
            "appVersion" : ,
            "appState" :,
            "isCrashed" :
            "isDeadLock" :
            "deadlockStack" : ,
            "isExit" : ,
            "ocurTime" :
            "startTime" :,
            "isOOMDetectorOpen" :,
            "crash_stage" : 
         }
         */
        NSDictionary *foomDict = [NSDictionary dictionaryWithObjectsAndKeys:residentMemory,@"lastMemory",[NSNumber numberWithUnsignedLongLong:_memWarningTimes],@"memWarning",_uuid,@"uuid",_systemVersion,@"systemVersion",_appVersion,@"appVersion",[NSNumber numberWithInt:(int)_appState],@"appState",[NSNumber numberWithBool:_isCrashed],@"isCrashed",[NSNumber numberWithBool:_isDeadLock],@"isDeadLock",_deadLockStack ? _deadLockStack : @"",@"deadlockStack",[NSNumber numberWithBool:_isExit],@"isExit",[NSNumber numberWithDouble:_ocurTime],@"ocurTime",[NSNumber numberWithDouble:_startTime],@"startTime",[NSNumber numberWithBool:_isOOMDetectorOpen],@"isOOMDetectorOpen",_crash_stage,@"crash_stage",nil];
        
        // 归档为二进制
        NSData *foomData = [NSKeyedArchiver archivedDataWithRootObject:foomDict];
        if(foomData && [foomData length] > 0)
        {
            // 清空 FOOM 日志
            _foomLogger->cleanLogger();
            int32_t length = (int32_t)[foomData length];
            
            if(!_foomLogger->memcpyLogger((const char *)&length, 4))
            {
                [[NSFileManager defaultManager] removeItemAtPath:_currentLogPath error:nil];
                delete _foomLogger;
                _foomLogger = NULL;
            }
            else
            {
                if(!_foomLogger->memcpyLogger((const char *)[foomData bytes],[foomData length])){
                    [[NSFileManager defaultManager] removeItemAtPath:_currentLogPath error:nil];
                    delete _foomLogger;
                    _foomLogger = NULL;
                }
            }
        }
    }
}

-(void)uploadLastData
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *foomDir = [self foomMemoryDir];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *paths = [fm contentsOfDirectoryAtPath:foomDir error:nil];
        for(NSString *path in paths)
        {
            if([path hasSuffix:@".oom"]){
                NSString *fullPath = [foomDir stringByAppendingPathComponent:path];
                if([fullPath isEqualToString:_currentLogPath]){
                    continue;
                }
                NSData *metaData = [NSData dataWithContentsOfFile:fullPath];
                if(metaData.length <= 4){
                    [fm removeItemAtPath:fullPath error:nil];
                    continue;
                }
                int32_t length = *(int32_t *)metaData.bytes;
                if(length <= 0 || length > [metaData length] - 4){
                    [fm removeItemAtPath:fullPath error:nil];
                }
                else {
                    NSData *foomData = [NSData dataWithBytes:(const char *)metaData.bytes + 4 length:(NSUInteger)length];
                    NSDictionary *foomDict = nil;
                    @try {
                        foomDict = [NSKeyedUnarchiver unarchiveObjectWithData:foomData];
                    }
                    @catch (NSException *e) {
                        foomDict = nil;
                        OOM_Log("unarchive FOOMData failed,length:%d,exception:%s!",length,[[e description] UTF8String]);
                    }
                    @finally{
                        if(foomDict && [foomDict isKindOfClass:[NSDictionary class]]){
                            NSString *uin = [foomDict objectForKey:@"uin"];
                            if(uin == nil || uin.length <= 0){
                                uin = @"10000";
                            }
                            NSDictionary *uploadData = [self parseFoomData:foomDict];
                            NSDictionary *aggregatedData = [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:uploadData],@"parts",nil];
                            NSString *uuid = [foomDict objectForKey:@"uuid"];
                            NSDictionary *basicParameter = [NSDictionary dictionaryWithObjectsAndKeys:uin,@"uin",uuid,@"client_identify",[foomDict objectForKey:@"ocurTime"],@"occur_time",nil];
                            [[QQLeakFileUploadCenter defaultCenter] fileData:aggregatedData extra:basicParameter type:QQStackReportTypeOOMLog completionHandler:nil];
                        }
                        [fm removeItemAtPath:fullPath error:nil];
                    }
                }
            }
        }
        [[OOMDetector getInstance] clearOOMLog];
    });
}

-(NSDictionary *)parseFoomData:(NSDictionary *)foomDict
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    [result setObject:@"sigkill" forKey:@"category"];
    NSNumber *startTime = [foomDict objectForKey:@"startTime"];
    if(startTime){
        [result setObject:startTime forKey:@"s"];
    }
    [result setObject:[foomDict objectForKey:@"ocurTime"] forKey:@"e"];
    [result setObject:[foomDict objectForKey:@"lastMemory"] forKey:@"mem_used"];
    [result setObject:[foomDict objectForKey:@"memWarning"] forKey:@"mem_warning_cnt"];
    NSString *crash_stage = [foomDict objectForKey:@"crash_stage"];
    if(crash_stage){
        [result setObject:crash_stage forKey:@"crash_stage"];
    }
    NSNumber *isOOMDetectorOpen_num = [foomDict objectForKey:@"isOOMDetectorOpen"];
    if(isOOMDetectorOpen_num){
        [result setObject:isOOMDetectorOpen_num forKey:@"enable_oom"];
    }
    else {
        [result setObject:@NO forKey:@"enable_oom"];
    }
    App_State appState = (App_State)[[foomDict objectForKey:@"appState"] intValue];
    BOOL isCrashed = [[foomDict objectForKey:@"isCrashed"] boolValue];
    if(appState == APPENTERFORGROUND){
        BOOL isExit = [[foomDict objectForKey:@"isExit"] boolValue];
        BOOL isDeadLock = [[foomDict objectForKey:@"isDeadLock"] boolValue];
        NSString *lastSysVersion = [foomDict objectForKey:@"systemVersion"];
        NSString *lastAppVersion = [foomDict objectForKey:@"appVersion"];
        if(!isCrashed && !isExit && [_systemVersion isEqualToString:lastSysVersion] && [_appVersion isEqualToString:lastAppVersion]){
            if(isDeadLock){
                OOM_Log("The app ocurred deadlock lastTime,detail info:%s",[[foomDict description] UTF8String]);
                [result setObject:@deadlock_crash forKey:@"crash_type"];
                NSDictionary *stack = [foomDict objectForKey:@"deadlockStack"];
                if(stack && stack.count > 0){
                    [result setObject:stack forKey:@"stack_deadlock"];
                    OOM_Log("The app deadlock stack:%s",[[stack description] UTF8String]);
                }
            }
            else {
                OOM_Log("The app ocurred foom lastTime,detail info:%s",[[foomDict description] UTF8String]);
                [result setObject:@foom_crash forKey:@"crash_type"];
                NSString *uuid = [foomDict objectForKey:@"uuid"];
                NSArray *oomStack = [[OOMDetector getInstance] getOOMDataByUUID:uuid];
                if(oomStack && oomStack.count > 0)
                {
                    NSData *oomData = [NSJSONSerialization dataWithJSONObject:oomStack options:0 error:nil];
                    if(oomData.length > 0){
//                        NSString *stackStr = [NSString stringWithUTF8String:(const char *)oomData.bytes];
                        OOM_Log("The app foom stack:%s",[[oomStack description] UTF8String]);
                    }
                    [result setObject:[self getAPMOOMStack:oomStack] forKey:@"stack_oom"];
                }
            }
            return result;
        }
    }
    if(isCrashed){
        OOM_Log("The app ocurred rqd crash lastTime,detail info:%s",[[foomDict description] UTF8String]);
        [result setObject:@normal_crash forKey:@"crash_type"];
    }
    else {
        OOM_Log("The app ocurred no crash lastTime,detail info:%s!",[[foomDict description] UTF8String]);
        [result setObject:@no_crash forKey:@"crash_type"];
    }
    [result setObject:@"" forKey:@"stack_deadlock"];
    [result setObject:@"" forKey:@"stack_oom"];
    return result;
}

-(NSDictionary *)getAPMOOMStack:(NSArray *)stack
{
    NSDictionary *slice = [NSDictionary dictionaryWithObjectsAndKeys:stack,@"threads",nil];
    NSArray *slicesArray = [NSArray arrayWithObject:slice];
    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:slicesArray,@"time_slices",nil];
    return result;
}

-(NSString*)foomMemoryDir
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *LibDirectory = [paths objectAtIndex:0];
    NSString *path = [LibDirectory stringByAppendingPathComponent:@"/Foom"];
    if(![[NSFileManager defaultManager] fileExistsAtPath:path]){
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return path;
}

/// 获取 resident 的内存大小值
- (double)appResidentMemory
{
    mach_task_basic_info_data_t taskInfo;
    unsigned infoCount = sizeof(taskInfo);
    kern_return_t kernReturn = task_info(mach_task_self(),
                                         MACH_TASK_BASIC_INFO,
                                         (task_info_t)&taskInfo,
                                         &infoCount);
    
    if (kernReturn != KERN_SUCCESS
        ) {
        return 0;
    }
    return taskInfo.resident_size / 1024.0 / 1024.0;
}

-(void)setOOMDetectorOpen:(BOOL)isOpen
{
    [_logLock lock];
    _isOOMDetectorOpen = isOpen;
    [self updateFoomData];
    [_logLock unlock];
}

/// SDK 内部的子线程更新crash identification，
/// @param stage name
-(void)updateStage:(NSString *)stage
{
    [self performSelector:@selector(_updateStage:) onThread:_thread withObject:stage waitUntilDone:NO];
}

-(void)_updateStage:(NSString *)stage
{
    [_logLock lock];
    _crash_stage = stage;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appReceiveMemoryWarning
{
    [self performSelector:@selector(_appReceiveMemoryWarning) onThread:_thread withObject:nil waitUntilDone:NO];
}

-(void)_appReceiveMemoryWarning
{
    [_logLock lock];
    _memWarningTimes++;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appDidEnterBackground
{
    [self performSelector:@selector(_appDidEnterBackground) onThread:_thread withObject:nil waitUntilDone:NO];
}

-(void)_appDidEnterBackground
{
    [_logLock lock];
    _appState = APPENTERBACKGROUND;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appWillEnterForground
{
    [self performSelector:@selector(_appWillEnterForground) onThread:_thread withObject:nil waitUntilDone:NO];
}

-(void)_appWillEnterForground
{
    [_logLock lock];
    if(_appState != APPDIDTERMINATE)
    {
        _appState = APPENTERFORGROUND;
        [self updateFoomData];
    }
    [_logLock unlock];
}

-(void)appWillTerminate
{
    [self _appWillTerminate];
}

-(void)_appWillTerminate
{
    [_logLock lock];
    _appState = APPDIDTERMINATE;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appDidCrashed
{
    [_logLock lock];
    _isCrashed = YES;
    [self updateFoomData];
    [_logLock unlock];
}

/// 更新 app 退出状态
-(void)appExit
{
    [_logLock lock];
    _isExit = YES;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appDetectDeadLock:(NSDictionary *)stack
{
    [_logLock lock];
    _isDeadLock = YES;
    _deadLockStack = stack;
//    _deadLockStack = stack;
    [self updateFoomData];
    [_logLock unlock];
}

-(void)appResumeFromDeadLock
{
    [_logLock lock];
    _isDeadLock = NO;
    _deadLockStack = nil;
    [self updateFoomData];
    [_logLock unlock];
}

/*! @brief 设置appVersion
 *
 * @param appVersion app版本号
 *
 */
-(void)setAppVersion:(NSString *)appVersion
{
    [_logLock lock];
    _appVersion = appVersion;
    [_logLock unlock];
}

@end
