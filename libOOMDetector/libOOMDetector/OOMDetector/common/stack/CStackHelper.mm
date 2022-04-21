//
//  CMachOHelper.m
//  QQLeak
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

#import "CStackHelper.h"
#import "RapidCRC.h"
#import "CommonMallocLogger.h"

#if __has_feature(objc_arc)
#error This file must be compiled without ARC. Use -fno-objc-arc flag.
#endif

/// 主App 镜像内存地址模型，只有 beginAddr 和 endAddr 两个变量
typedef struct
{
    vm_address_t beginAddr;
    vm_address_t endAddr;
}App_Address;

/// 三个 App_Address 元素的全局数组
static App_Address app_addrs[3];

/// 析构函数， 释放通过 malloc 申请的 allImages 占用的内存空间。
CStackHelper::~CStackHelper()
{
    for (size_t i = 0; i < allImages.size; i++)
    {
        free(allImages.imageInfos[i]);
    }
    free(allImages.imageInfos);
    allImages.imageInfos = NULL;
    allImages.size = 0;
}


/// 构造函数
/// @param saveDir 保存数据的路径。这里应该是 Library/OOMDetector_New/${uuid}/app.images
CStackHelper::CStackHelper(NSString *saveDir)
{
    // 通过 dyld 获取所有的镜像数据
    uint32_t count = _dyld_image_count();
    
    // 开辟并初始化 allImages
    allImages.imageInfos =(segImageInfo **)malloc(count*sizeof(segImageInfo*));
    allImages.size = 0;
    
    for (uint32_t i = 0; i < count; i++) {
        // MachO header
        const mach_header_t* header = (const mach_header_t*)_dyld_get_image_header(i);
        // image 镜像名称
        const char* name = _dyld_get_image_name(i);
        // '/' 做截取
        const char* tmp = strrchr(name, '/');
        // aslr 偏移
        long slide = _dyld_get_image_vmaddr_slide(i);
        if (tmp) {
            // name 只赋值文件名，去除目录路径名，示例 由 "/usr/lib/libBacktraceRecording.dylib" => "libBacktraceRecording.dylib"
            name = tmp + 1;
        }
        // Load command 起始偏移
        long offset = (long)header + sizeof(mach_header_t);
        
        // 遍历所有的 segment
        for (unsigned int j = 0; j < header->ncmds; j++) {
            const segment_command_t* segment = (const segment_command_t*)offset;
            // 存在'__Text'代码段，同时 command 类型为 LC_SEGMENT_64的lc。实际上只有一个__Text，所以虽然是在 for 中，但是 image 初始化最多执行一次。
            if (segment->cmd == MY_SEGMENT_CMD_TYPE && strcmp(segment->segname, SEG_TEXT) == 0) {
                // 起始地址为 aslr + 虚拟地址（映射到内存后的地址）= 实际运行时内存中的地址
                long begin = (long)segment->vmaddr + slide;
                
                // 结束地址
                long end = (long)(begin + segment->vmsize);
                segImageInfo *image = (segImageInfo *)malloc(sizeof(segImageInfo));
                image->loadAddr = (long)header;
                image->beginAddr = begin;
                image->endAddr = end;
                image->name = name;
#ifdef build_for_QQ
                // 针对 QQ, 记录三个镜像地址，包括 TlibDy、QQMainProject、QQStoryCommon
                static int index = 0;
                if((strcmp(name, "TlibDy") == 0 || strcmp(name, "QQMainProject") == 0  || strcmp(name, "QQStoryCommon") == 0) && index < 3)
                {
                    app_addrs[index].beginAddr = image->beginAddr;
                    app_addrs[index++].endAddr = image->endAddr;
                }
#else
                // 第零个镜像一般是主 app 镜像。
                if(i == 0){
                    app_addrs[0].beginAddr = image->beginAddr;
                    app_addrs[0].endAddr = image->endAddr;
                }
#endif
                allImages.imageInfos[allImages.size++] = image;
                break;
            }
            
            // 更新偏移
            offset += segment->cmdsize;
        }
    }
    if(saveDir){
        saveImages(saveDir);
    }
}

/// 写入文件
/// @param saveDir 指定的路径
void CStackHelper::saveImages(NSString *saveDir)
{
    // 异步写入到文件
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *result = [[[NSMutableArray alloc] init] autorelease];
        for (size_t i = 0; i < allImages.size; i++)
        {
            NSString *imageName = [NSString stringWithCString:allImages.imageInfos[i]->name encoding:NSUTF8StringEncoding];
            NSDictionary *app_image = [NSDictionary dictionaryWithObjectsAndKeys:imageName,@"name",[NSNumber numberWithInteger:allImages.imageInfos[i]->beginAddr],@"beginAddr",[NSNumber numberWithInteger:allImages.imageInfos[i]->endAddr],@"endAddr",nil];
            [result addObject:app_image];
        }
        NSString *save_path = [saveDir stringByAppendingPathComponent:@"app.images"];
        [result writeToFile:save_path atomically:YES];
    });
}

/// 解析镜像文件数据
/// @param imageArray 镜像文件数据
AppImages* CStackHelper::parseImages(NSArray *imageArray)
{
    // 开辟空间并初始化
    AppImages *result = new AppImages();
    result->size = 0;
    result->imageInfos = (segImageInfo **)malloc([imageArray count]*sizeof(segImageInfo*));
    // 遍历开始赋值 result
    for(NSDictionary *image in imageArray){
        NSNumber *beginAddr = [image objectForKey:@"beginAddr"];
        NSNumber *endAddr = [image objectForKey:@"endAddr"];
        NSString *name = [image objectForKey:@"name"];
        if(beginAddr && endAddr && name){
            segImageInfo *image = (segImageInfo *)malloc(sizeof(segImageInfo));
            image->loadAddr = [beginAddr integerValue];
            image->beginAddr = [beginAddr integerValue];;
            image->endAddr = [endAddr integerValue];;
            image->name = [name UTF8String];
            result->imageInfos[result->size++] = image;
        }
    }
    
    return result;
}

/// 解析虚拟内存地址所属镜像对象，根据镜像 beginAddr 和 endAddr 范围匹配
/// @param images 镜像列表
/// @param addr 虚拟内存地址
/// @param image 所属的镜像对象，通过指针的方式赋值，
/// @return bool 返回是否查找到结果
bool CStackHelper::parseAddrOfImages(AppImages *images,vm_address_t addr,segImageInfo *image){
    for (size_t i = 0; i < images->size; i++)
    {
        // 如果地址匹配查找到的镜像范围内，则赋值
        if (addr > images->imageInfos[i]->beginAddr && addr < images->imageInfos[i]->endAddr) {
            image->name = images->imageInfos[i]->name;
            image->loadAddr = images->imageInfos[i]->loadAddr;
            image->beginAddr = images->imageInfos[i]->beginAddr;
            image->endAddr = images->imageInfos[i]->endAddr;
            return true;
        }
    }
    
    return false;
}

/// 判断虚拟内存地址是否位于 main app 中。通过 app 内存地址范围匹配。
/// @param addr 指定虚拟内存地址。
bool CStackHelper::isInAppAddress(vm_address_t addr) {
    if((addr >= app_addrs[0].beginAddr && addr < app_addrs[0].endAddr)
#ifdef build_for_QQ
       || (addr >= app_addrs[1].beginAddr && addr < app_addrs[1].endAddr) || (addr >= app_addrs[2].beginAddr && addr < app_addrs[2].endAddr)
#endif
       )
    {
        return true;
    }
    return false;
}

/// 和 parseAddrOfImages 目的一直， 解析指定内存地址所在的 image, 不过数据来源是 allImages，不需要入参传入
/// @param addr 虚拟内存地址
/// @param image 通过指针传入的 image 模型对象， 可以视为返回值。
/// @return bool 返回是否获取成功。
bool CStackHelper::getImageByAddr(vm_address_t addr,segImageInfo *image){
    for (size_t i = 0; i < allImages.size; i++)
    {
        if (addr > allImages.imageInfos[i]->beginAddr && addr < allImages.imageInfos[i]->endAddr) {
            image->name = allImages.imageInfos[i]->name;
            image->loadAddr = allImages.imageInfos[i]->loadAddr;
            image->beginAddr = allImages.imageInfos[i]->beginAddr;
            image->endAddr = allImages.imageInfos[i]->endAddr;
            return true;
        }
    }
    return false;
}

/// 记录当前调用栈
/// @param needSystemStack 是否记录系统函数调用堆栈
/// @param type 调用堆栈记录类型
/// @param needAppStackCount 记录需要存储的 app image 堆栈数量, 所有调用传入的值都是 0.
/// @param backtrace_to_skip 忽略的堆栈深度
/// @param app_stack 存储调用堆栈的内存地址
/// @param digest 摘要信息
/// @param max_stack_depth 最大堆栈深度
/// @return 返回堆栈深度
size_t CStackHelper::recordBacktrace(BOOL needSystemStack,uint32_t type ,size_t needAppStackCount,size_t backtrace_to_skip, vm_address_t **app_stack,uint64_t *digest,size_t max_stack_depth)
{
    // 记录调用栈列表
    vm_address_t *orig_stack[max_stack_depth_sys];
    /**
     backtrace：该函数用于获取当前线程的函数调用堆栈，获取的信息将存放在buffer中，
        - buffer是一个二级指针，可以当作指针数组来用，数组中的元素类型是void*，即从堆栈中获取的返回地址，每一个堆栈框架stack frame有一个返回地址，
        - 参数 size 用来指定buffer中可以保存void* 元素的最大值，
        - 函数返回值是buffer中实际获取的void*指针个数，最大不超过参数size的大小。
     */
    // 更新堆栈的深度。 depth是实际深度。
    size_t depth = backtrace((void**)orig_stack, max_stack_depth_sys);
    size_t orig_depth = depth;
    
    // 如果超过了给定深度，则只使用给定深度部分的地址。（这里为什么不一开始就使用给定深度做backtrace，不然不会造成性能损耗吗
    if(depth > max_stack_depth){
        depth = max_stack_depth;
    }
    
    // 初始化数组，初始值为'\0'，'\0'一般表示字符串的结束
    uint32_t compress_stacks[max_stack_depth_sys] = {'\0'};
    
    // 记录索引
    size_t offset = 0;
    // 记录有多少栈帧是属于 main app 的。在 needAppStackCount == 1 时会使用。
    size_t appstack_count = 0;
    
    // 如果深度 小于给定的 3 + backtrace_to_skip， 则直接返回不处理 这里 + 3 的目的是什么？？？(猜测是如果调用栈过少，没啥解析的必要）
    if(depth <= 3 + backtrace_to_skip) {
        return 0;
    }
    
    // 实际长度为深度 - 忽略堆栈深度 - 2 （2可能是表示的每一个堆栈都存在的共同栈帧，所以无需处理）
    size_t real_length = depth - 2 - backtrace_to_skip;
    size_t index = 0;
    
    // 第一个元素记录的是类型，后续记录的是内存地址。
    compress_stacks[index++] = type;
    
    // 从 backtrace_to_skip 忽略深度开始遍历，直到结尾。
    for(size_t j = backtrace_to_skip;j < backtrace_to_skip + real_length;j++) {
        //  SDK 里所有调用处 needAppStackCount == 0 ，所以直接跳转值 else 执行。
        if(needAppStackCount != 0) {
            // 判断是否是从属于 main app 的镜像文件地址
            if(isInAppAddress((vm_address_t)orig_stack[j])) {
                
                // 更新计数器
                appstack_count++;
                
                // 存储栈帧内存地址。
                app_stack[offset++] = orig_stack[j];
                
                // 存储到记录压缩堆栈的数组中
                compress_stacks[index++] = (uint32_t)(uint64_t)orig_stack[j];
            }
            else {
                // 如果地址不从属于 main image 模块，则判断是否需要记录系统堆栈。
                if(needSystemStack) {
                    // 需要记录系统堆栈则添加进结果数组中。否则直接忽略
                    app_stack[offset++] = orig_stack[j];
                    compress_stacks[index++] = (uint32_t)(uint64_t)orig_stack[j];
                }
            }
        }
        else{
            // 默认所有堆栈全部记录。
            app_stack[offset++] = orig_stack[j];
            compress_stacks[index++] = (uint32_t)(uint64_t)orig_stack[j];
        }
    }
    
    // 处理完之后，将开始获取的堆栈数据倒数第二个栈帧存储。
    app_stack[offset] = orig_stack[orig_depth - 2];
    
    // 如果设置了只获取 main image 堆栈并且存在调用栈帧 || 未设置只记录 main image 的标识并且存在栈帧（包括系统和main image）=> 一句话理解就是存在调用想要的调用堆栈
    if((needAppStackCount > 0 && appstack_count > 0) || (needAppStackCount == 0 && offset > 0)) {
        // 文件完整性校验
        size_t remainder = (index * 4) % 8;
        size_t compress_len = index * 4 + (remainder == 0 ? 0 : (8 - remainder));
        
        //    最早的版本是直接通过 MD5 做摘要
        //    CC_MD5(&compress_stacks,(CC_LONG)2*depth,md5);
        //    memcpy(md5, &compress_stacks, 16);
        //    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
        //    CC_SHA1(&compress_stacks,(CC_LONG)2*depth, md5);
        
        // 改为 crc64 做完整性校验
        uint64_t crc = 0;
        crc = rapid_crc64(crc, (const char *)&compress_stacks, compress_len);
        *digest = crc;
        return offset + 1;
    }
    
    // 默认返回 0
    return 0;
}
