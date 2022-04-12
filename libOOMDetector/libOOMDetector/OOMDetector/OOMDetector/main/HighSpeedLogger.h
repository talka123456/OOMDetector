//
//  HighSpeedLogger.h
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

#ifndef HighSpeedLogger_h
#define HighSpeedLogger_h

#import <Foundation/Foundation.h>
#import <malloc/malloc.h>

// 定义函数指针，
typedef void (*LogPrinter)(char *log);

/// mmap 工具类
class HighSpeedLogger
{
public:
    // 析构函数
    ~HighSpeedLogger();
    // 构造函数
    HighSpeedLogger(malloc_zone_t *zone, NSString *path, size_t mmap_size);
    // 写入数据（虚拟内存空间）
    BOOL memcpyLogger(const char *content, size_t length);
    // 清空数据，（清空的只是虚拟内存数据。）
    void cleanLogger();
    // 内存 -> 磁盘同步数据
    void syncLogger();
    // 校验对象合法性
    bool isValid();
    LogPrinter logPrinterCallBack;
public:
    char *mmap_ptr; //!< mmap 映射的起始地址指针
    size_t mmap_size; //!< mmap 映射的虚拟内存大小
    size_t current_len; //!< 当前字节长度
    malloc_zone_t *memory_zone; //!< mmap 映射的 zone
    FILE *mmap_fp; //!< 操作文件的指针
    bool isFailed; //!< 状态标识符
};

#endif /* HighSpeedLogger_h */
