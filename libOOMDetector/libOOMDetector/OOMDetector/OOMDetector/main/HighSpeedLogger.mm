//
//  HighSpeedLogger.m
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

#import "HighSpeedLogger.h"
/// 需要导入头文件
#import <sys/mman.h>

// 要求 非ARC 环境编译
#if __has_feature(objc_arc)
#error This file must be compiled without ARC. Use -fno-objc-arc flag.
#endif

/**
 [C++/C--mmap()详解](https://blog.csdn.net/baidu_38172402/article/details/106673606)
 [C语言mmap()函数：建立内存映射](http://c.biancheng.net/cpp/html/138.html)
 
 将一个文件或者其它对象映射进内存, 要求必须以内存页大小为单位，若要映射非PAGE_SIZE整数倍的地址范围，要先进行内存对齐，
 
 函数原型：
 void* mmap(void* start,size_t length,int prot,int flags,int fd,off_t offset);
 int munmap(void* start,size_t length);
 
 start: 映射区的起始位置， 设置为0时表示由系统决定映射区的起始地址。
 length:  映射区的长度。//长度单位是 以字节为单位，不足一内存页按一内存页处理
 prot： 期望的内存保护标志，不能与文件的打开模式冲突。是以下的某个值，可以通过or运算合理地组合在一起
    - PROT_EXEC //页内容可以被执行
    - PROT_READ //页内容可以被读取
    - PROT_WRITE //页可以被写入
    - PROT_NONE //页不可访问
 flags： 指定映射对象的类型，映射选项和映射页是否可以共享。它的值可以是一个或者多个以下位的组合体（这里只写用到的两个）
    - MAP_SHARED：//与其它所有映射这个对象的进程共享映射空间。对共享区的写入，相当于输出到文件。（直到msync()或者munmap()被调用，文件实际上不会被更新。）
    - MAP_FILE // 兼容标志，被忽略
 
 fd：有效的文件描述词。一般是由open()函数返回，其值也可以设置为-1，此时需要指定flags参数中的MAP_ANON,表明进行的是匿名映射。
 off_toffset： 被映射对象内容的起点。
 
 返回值：
 成功：mmap()返回被映射区的指针，munmap()返回0。
 失败：mmap()返回MAP_FAILED[其值为(void *)-1]，munmap返回-1。
 */

// 析构函数
HighSpeedLogger::~HighSpeedLogger()
{
    if(mmap_ptr != NULL)
    {
        munmap(mmap_ptr , mmap_size);
    }
}


/// 析构函数
/// @param zone malloc create zone
/// @param path 文件路径
/// @param size 映射大小
HighSpeedLogger::HighSpeedLogger(malloc_zone_t *zone, NSString *path, size_t size)
{
    current_len = 0;
    mmap_size = size;
    memory_zone = zone;
    isFailed = false;
    /**
     C 库函数 FILE *fopen(const char *filename, const char *mode) 使用给定的模式 mode 打开 filename 所指向的文件。
     https://www.runoob.com/cprogramming/c-function-fopen.html    w：创建一个用于写入的空文件。如果文件名称与已存在的文件相同，则会删除已有文件的内容，文件被视为一个新的空文件。
     b: 表示二进制文件
     
     wb+ 读写打开或建立一个二进制文件，允许读和写。
     */
    FILE *fp = fopen ( [path fileSystemRepresentation] , "wb+" ) ;
    if(fp != NULL){
        /**
         ftruncate()会将参数fd 指定的文件大小改为参数length 指定的大小。
         参数fd 为已打开的文件描述词，而且必须是以写入模式打开的文件。如果原来的文件大小比参数length 大，则超过的部分会被删去。
         执行成功则返回0, 失败返回-1, 错误原因存于errno.
         */
        
        /**
         FILE: 这是一个适合存储文件流信息的对象类型。
         fileno: fileno()用来取得参数stream 指定的文件流所使用的文件描述词. 返回 int 类型
         */
        int ret = ftruncate(fileno(fp), size);
        if(ret == -1){
            // 失败标识符重置为 true
            isFailed = true;
        }
        else {
            // 设置流 stream 的文件位置为给定的偏移 offset. 参数 offset 意味着从给定的 whence 位置查找的字节数。 fseek(fp, 0, SEEK_SET) 代表将文件指针指向起始位置。
            fseek(fp, 0, SEEK_SET);
            // 开辟虚拟内存空间， 返回该地址
            char *ptr = (char *)mmap(0, size, PROT_WRITE | PROT_READ, (MAP_FILE|MAP_SHARED), fileno(fp), 0);
            // 所有字符重置为'\0'
            memset(ptr, '\0', size);
            if(ptr != NULL)
            {
                // 记录当前文件虚拟内存指针以及文件描述对象
                mmap_ptr = ptr;
                mmap_fp = fp;
            }
            else {
                isFailed = true;
            }
        }
    }
    else {
        isFailed = true;
    }
}


/// 写入内容
/// @param content 内存二进制流
/// @param length 长度（字节）
BOOL HighSpeedLogger::memcpyLogger(const char *content, size_t length)
{
    BOOL result = NO;
    // 如果写入长度 + 已写入长度 < mmap 虚拟内存大小, 则直接 memcpy 拷贝到虚拟内存即可
    if(length + current_len <= mmap_size) {
        // 拷贝 content 的内容到 mmap_ptr + current_len定位处，写入长度为 length
        memcpy(mmap_ptr + current_len, content, length);
        // 更新当前长度
        current_len += length;
        result = YES;
    }
    else {
        // 扩容操作
        // 开辟已有数据大小的虚拟内存堆空间。
        char *copy = (char *)memory_zone->malloc(memory_zone, mmap_size);
        // 数据赋值到开辟的堆空间
        memcpy(copy, mmap_ptr, mmap_size);
        size_t copy_size = mmap_size;
        
        // 解除这一部分mmap虚拟内存空间映射关系
        munmap(mmap_ptr ,mmap_size);
        // 新的大小
        mmap_size = current_len + length;
        
        int ret = ftruncate(fileno(mmap_fp), mmap_size);
        if(ret == -1){
            memory_zone->free(memory_zone,copy);
            result = NO;
        }
        else {
            // 文件流指针重置到起始位置
            fseek(mmap_fp, 0, SEEK_SET);
            // 新映射 mmap 虚拟内存空间并重置成员变量值
            mmap_ptr = (char *)mmap(0, mmap_size, PROT_WRITE | PROT_READ, (MAP_FILE|MAP_SHARED), fileno(mmap_fp), 0);
            if(mmap_ptr == NULL){
                // 如果映射失败，则重置所有状态，并释放内存空间
                mmap_size = 0;
                current_len = 0;
                memory_zone->free(memory_zone,copy);
                result = NO;
            }
            else {
                // 映射成功， 虚拟内存初始化为 '\0'
                memset(mmap_ptr, '\0', mmap_size);
                result = YES;
                // 拷贝缓存的内存
                memcpy(mmap_ptr, copy, copy_size);
                // 拷贝新增的内容
                memcpy(mmap_ptr + current_len, content, length);
                current_len += length;
                // 释放临时申请的堆空间。
                memory_zone->free(memory_zone,copy);
            }
        }
    }
    return result;
}

/// 清空
void HighSpeedLogger::cleanLogger()
{
    current_len = 0;
    memset(mmap_ptr, '\0', mmap_size);
}

/// 同步虚拟内存到磁盘
void HighSpeedLogger::syncLogger()
{
    /**
     msync()函数详解：
     引入头文件 #include <sys/mman.h>
     
     原型：
     int msync(void *addr, size_t len, int flags);
     参数：
     addr : 文件映射的进程空间地址
     len: 映射的空间大小
     flags: 刷新策略，可取值为MS_ASYNC、MS_SYNC、MS_INVALIDATE
        - MS_ASYNC 异步刷新， 调用立即返回，不会等更新完成
        - MS_SYNC 同步刷新，更新完成再返回
        - MS_INVALIDATE（通知使用该共享区域的进程，数据已经改变）时，在共享内容更改之后，使得文件的其他映射失效，从而使得共享该文件的其他进程去重新获取最新值；
     
     返回值：成功为 0，失败为 1.
    不太理解这里既然 mmap 使用了 MAP_SHARED， msync 为什么没使用 MS_INVALIDATE 呢，
     */
    msync(mmap_ptr, mmap_size, MS_ASYNC);
}

/// 返回是否有效
bool HighSpeedLogger::isValid()
{
    return !isFailed;
}
