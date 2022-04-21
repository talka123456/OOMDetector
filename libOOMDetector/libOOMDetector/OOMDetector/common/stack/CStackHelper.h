//
//  CStackHelper.h
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


#ifndef CStackHelper_h
#define CStackHelper_h

#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <vector>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import "QQLeakPredefines.h"
#import <mach/vm_types.h>
#import "execinfo.h"
#import <CommonCrypto/CommonDigest.h>
#import "CBaseHashmap.h"
#import "CStacksHashmap.h"
#import "CPtrsHashmap.h"
#import <Foundation/Foundation.h>

/// 镜像信息， 包括加载路径， 起始地址， 结束地址， 名称信息
typedef struct
{
    const char* name;
    long loadAddr;
    long beginAddr;
    long endAddr;
}segImageInfo;

/// 镜像模型，包括个数和 segImageInfo镜像信息
typedef struct AppImages
{
    size_t size;
    segImageInfo **imageInfos;
}AppImages;


/// 处理 Image 镜像相关的类，包含生成、解析、存储、读取等。
class CStackHelper
{
public:
    /// 构造函数，入参为数据保存路径
    CStackHelper(NSString *saveDir);
    
    /// 析构函数，释放通过 malloc 申请的 allImages 占用的内存空间。
    ~CStackHelper();
    
    /**
        解析 Images 镜像信息，imagesData 是plist 文件中的数组，单个镜像数据对应格式为：
         <key>beginAddr</key>
         <integer>8158666752</integer>
         <key>endAddr</key>
         <integer>8158699520</integer>
         <key>name</key>
         <string>libBacktraceRecording.dylib</string>
     */
    
    static AppImages* parseImages(NSArray *imageArray);
    static bool parseAddrOfImages(AppImages *images,vm_address_t addr,segImageInfo *image);
    bool isInAppAddress(vm_address_t addr);
    bool getImageByAddr(vm_address_t addr,segImageInfo *image);
    size_t recordBacktrace(BOOL needSystemStack,uint32_t type ,size_t needAppStackCount,size_t backtrace_to_skip, vm_address_t **app_stack,uint64_t *digest,size_t max_stack_depth);
private:
    void saveImages(NSString *saveDir);
private:
    /// 成员变量，所有的 image 模型对象
    AppImages allImages;
};

#endif /* CMachOHelpler_h */
