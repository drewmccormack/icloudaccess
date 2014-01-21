//
//  ICACloud
//  iCloud Access
//
//  Created by Drew McCormack on 18/01/14.
//  Copyright (c) 2014 Drew McCormack. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSString *ICAException;
extern NSString *ICAErrorDomain;

typedef NS_ENUM(NSInteger, ICAErrorCode) {
    ICAErrorCodeFileAccessFailed            = 100,
    ICAErrorCodeFileCoordinatorTimedOut     = 101,
    ICAErrorCodeAuthenticationFailure       = 102,
    ICAErrorCodeConnectionError             = 103
};


@interface ICACloudFile : NSObject

@property (readonly, copy) NSString *path;
@property (readonly, copy) NSString *name;
@property (readonly) NSDictionary *fileAttributes;

@end


@interface ICACloud : NSObject

@property (nonatomic, assign, readonly) BOOL isConnected;
@property (nonatomic, strong, readonly) id <NSObject, NSCopying, NSCoding> identityToken; // Fires KVO Notifications
@property (nonatomic, readonly) NSString *rootDirectoryPath; // Container relative

- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier;
- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier rootDirectoryPath:(NSString *)newPath;

- (void)fileExistsAtPath:(NSString *)path completion:(void(^)(BOOL exists, BOOL isDirectory, NSError *error))block;

- (void)createDirectoryAtPath:(NSString *)path completion:(void(^)(NSError *error))block;
- (void)contentsOfDirectoryAtPath:(NSString *)path completion:(void(^)(NSArray *contents, NSError *error))block;

- (void)removeItemAtPath:(NSString *)fromPath completion:(void(^)(NSError *error))block;

- (void)uploadLocalFile:(NSString *)fromPath toPath:(NSString *)toPath completion:(void(^)(NSError *error))block;
- (void)downloadFromPath:(NSString *)fromPath toLocalFile:(NSString *)toPath completion:(void(^)(NSError *error))block;

- (void)uploadData:(NSData *)data toPath:(NSString *)toPath completion:(void(^)(NSError *error))block;
- (void)downloadDataFromPath:(NSString *)fromPath completion:(void(^)(NSData *data, NSError *error))block;

@end
