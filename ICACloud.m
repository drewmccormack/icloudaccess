//
//  ICACloud
//  iCloud Access
//
//  Created by Drew McCormack on 18/01/14.
//  Copyright (c) 2014 Drew McCormack. All rights reserved.
//

#import "ICACloud.h"

NSString *ICAException = @"ICAException";
NSString *ICAErrorDomain = @"ICAErrorDomain";



@interface ICACloudFile ()

@property (readwrite, copy) NSString *path;
@property (readwrite, copy) NSString *name;
@property (readwrite) NSDictionary *fileAttributes;

@end


@implementation ICACloudFile

@synthesize path = path;
@synthesize name = name;
@synthesize fileAttributes = fileAttributes;

@end


@implementation ICACloud {
    NSFileManager *fileManager;
    NSURL *rootDirectoryURL;
    NSMetadataQuery *metadataQuery;
    NSOperationQueue *operationQueue;
    NSString *ubiquityContainerIdentifier;
    dispatch_queue_t timeOutQueue;
    id ubiquityIdentityObserver;
}

@synthesize rootDirectoryPath = rootDirectoryPath;

// Designated
- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier rootDirectoryPath:(NSString *)newPath
{
    self = [super init];
    if (self) {
        fileManager = [[NSFileManager alloc] init];
        
        rootDirectoryPath = [newPath copy] ? : @"";
        
        operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.maxConcurrentOperationCount = 1;
        
        timeOutQueue = dispatch_queue_create("com.mentalfaculty.cloudaccess.queue.icloudtimeout", DISPATCH_QUEUE_SERIAL);
        
        rootDirectoryURL = nil;
        metadataQuery = nil;
        ubiquityContainerIdentifier = [newIdentifier copy];
        ubiquityIdentityObserver = nil;
        
        [self performInitialPreparation:NULL];
    }
    return self;
}

- (instancetype)initWithUbiquityContainerIdentifier:(NSString *)newIdentifier
{
    return [self initWithUbiquityContainerIdentifier:newIdentifier rootDirectoryPath:nil];
}

- (instancetype)init
{
    @throw [NSException exceptionWithName:ICAException reason:@"iCloud initializer requires container identifier" userInfo:nil];
    return nil;
}

- (void)dealloc
{
    [self removeUbiquityContainerNotificationObservers];
    [self stopMonitoring];
    [operationQueue cancelAllOperations];
}

#pragma mark - User Identity

- (id <NSObject, NSCoding, NSCopying>)identityToken
{
    return [fileManager ubiquityIdentityToken];
}

#pragma mark - Initial Preparation

- (void)performInitialPreparation:(void(^)(NSError *error))completion
{
    if (fileManager.ubiquityIdentityToken) {
        [self setupRootDirectory:^(NSError *error) {
            [self startMonitoringMetadata];
            [self addUbiquityContainerNotificationObservers];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
        }];
    }
    else {
        [self addUbiquityContainerNotificationObservers];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil);
        });
    }
}

#pragma mark - Root Directory

- (void)setupRootDirectory:(void(^)(NSError *error))completion
{
    [operationQueue addOperationWithBlock:^{
        NSURL *newURL = [fileManager URLForUbiquityContainerIdentifier:ubiquityContainerIdentifier];
        newURL = [newURL URLByAppendingPathComponent:rootDirectoryPath];
        rootDirectoryURL = newURL;
        if (!rootDirectoryURL) {
            NSError *error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileAccessFailed userInfo:@{NSLocalizedDescriptionKey : @"Could not retrieve URLForUbiquityContainerIdentifier. Check container id for iCloud."}];
            [self dispatchCompletion:completion withError:error];
            return;
        }
        
        NSError *error = nil;
        __block BOOL fileExistsAtPath = NO;
        __block BOOL existingFileIsDirectory = NO;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:rootDirectoryURL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *newURL) {
            fileExistsAtPath = [fileManager fileExistsAtPath:newURL.path isDirectory:&existingFileIsDirectory];
        }];
        if (error) {
            [self dispatchCompletion:completion withError:error];
            return;
        }
        
        if (!fileExistsAtPath) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:0 error:&error byAccessor:^(NSURL *newURL) {
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        else if (fileExistsAtPath && !existingFileIsDirectory) {
            [coordinator coordinateWritingItemAtURL:rootDirectoryURL options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *newURL) {
                [fileManager removeItemAtURL:newURL error:NULL];
                [fileManager createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:NULL];
            }];
        }
        
        [self dispatchCompletion:completion withError:error];
    }];
}

- (void)dispatchCompletion:(void(^)(NSError *error))completion withError:(NSError *)error
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (completion) completion(error);
    });
}

- (NSString *)fullPathForPath:(NSString *)path
{
    return [rootDirectoryURL.path stringByAppendingPathComponent:path];
}

#pragma mark - Notifications

- (void)removeUbiquityContainerNotificationObservers
{
    [[NSNotificationCenter defaultCenter] removeObserver:ubiquityIdentityObserver];
    ubiquityIdentityObserver = nil;
}

- (void)addUbiquityContainerNotificationObservers
{
    [self removeUbiquityContainerNotificationObservers];
    
    __weak typeof(self) weakSelf = self;
    ubiquityIdentityObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUbiquityIdentityDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf stopMonitoring];
        [strongSelf willChangeValueForKey:@"identityToken"];
        [strongSelf didChangeValueForKey:@"identityToken"];
        [self connect];
    }];
}

#pragma mark - Connection

- (BOOL)isConnected
{
    return fileManager.ubiquityIdentityToken != nil;
}

- (void)connect
{
    BOOL loggedIn = fileManager.ubiquityIdentityToken != nil;
    if (loggedIn) [self performInitialPreparation:NULL];
}

#pragma mark - Metadata Query to download new files

- (void)startMonitoringMetadata
{
    [self stopMonitoring];
 
    if (!rootDirectoryURL) return;
    
    // Determine downloading key and set the appropriate predicate. This is OS dependent.
    NSPredicate *metadataPredicate = nil;
    
#if (__IPHONE_OS_VERSION_MIN_REQUIRED < 70000) && (__MAC_OS_X_VERSION_MIN_REQUIRED < 1090)
    metadataPredicate = [NSPredicate predicateWithFormat:@"%K = FALSE AND %K = FALSE AND %K BEGINSWITH %@",
        NSMetadataUbiquitousItemIsDownloadedKey, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemPathKey, rootDirectoryURL.path];
#else
    metadataPredicate = [NSPredicate predicateWithFormat:@"%K != %@ AND %K = FALSE AND %K BEGINSWITH %@",
        NSMetadataUbiquitousItemDownloadingStatusKey, NSMetadataUbiquitousItemDownloadingStatusCurrent, NSMetadataUbiquitousItemIsDownloadingKey, NSMetadataItemPathKey, rootDirectoryURL.path];
#endif
    
    metadataQuery = [[NSMetadataQuery alloc] init];
    metadataQuery.notificationBatchingInterval = 10.0;
    metadataQuery.searchScopes = [NSArray arrayWithObject:NSMetadataQueryUbiquitousDataScope];
    metadataQuery.predicate = metadataPredicate;
    
    NSNotificationCenter *notifationCenter = [NSNotificationCenter defaultCenter];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [notifationCenter addObserver:self selector:@selector(initiateDownloads:) name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    [metadataQuery startQuery];
}

- (void)stopMonitoring
{
    if (!metadataQuery) return;
    
    [metadataQuery disableUpdates];
    [metadataQuery stopQuery];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:metadataQuery];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidUpdateNotification object:metadataQuery];
    
    metadataQuery = nil;
}

- (void)initiateDownloads:(NSNotification *)notif
{
    [metadataQuery disableUpdates];
    
    NSUInteger count = [metadataQuery resultCount];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    for ( NSUInteger i = 0; i < count; i++ ) {
        @autoreleasepool {
            NSMetadataItem *item = [metadataQuery resultAtIndex:i];
            [self resolveConflictsForMetadataItem:item];
            
            NSURL *url = [item valueForAttribute:NSMetadataItemURLKey];
            dispatch_async(queue, ^{
                NSError *error;
                [fileManager startDownloadingUbiquitousItemAtURL:url error:&error];
            });
        }
    }

    [metadataQuery enableUpdates];
}

- (void)resolveConflictsForMetadataItem:(NSMetadataItem *)item
{
    NSURL *fileURL = [item valueForAttribute:NSMetadataItemURLKey];
    BOOL inConflict = [[item valueForAttribute:NSMetadataUbiquitousItemHasUnresolvedConflictsKey] boolValue];
    if (inConflict) {
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        __block BOOL coordinatorExecuted = NO;
        __block BOOL timedOut = NO;

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                timedOut = YES;
                [coordinator cancel];
            }
        });
        
        NSError *coordinatorError = nil;
        [coordinator coordinateWritingItemAtURL:fileURL options:NSFileCoordinatorWritingForDeleting error:&coordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timedOut) return;
            [NSFileVersion removeOtherVersionsOfItemAtURL:newURL error:nil];
        }];
        if (timedOut || coordinatorError) return;
        
        NSArray *conflictVersions = [NSFileVersion unresolvedConflictVersionsOfItemAtURL:fileURL];
        for (NSFileVersion *fileVersion in conflictVersions) {
            fileVersion.resolved = YES;
        }
    }
}

#pragma mark - File Operations

static const NSTimeInterval ICAFileCoordinatorTimeOut = 10.0;

- (NSError *)specializedErrorForCocoaError:(NSError *)cocoaError
{
    NSError *error = cocoaError;
    if ([cocoaError.domain isEqualToString:NSCocoaErrorDomain] && cocoaError.code == NSUserCancelledError) {
        error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
    }
    return error;
}

- (NSError *)notConnectedError
{
    NSError *error = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeConnectionError userInfo:@{NSLocalizedDescriptionKey : @"Attempted to access iCloud when not connected."}];
    return error;
}

- (void)fileExistsAtPath:(NSString *)path completion:(void(^)(BOOL exists, BOOL isDirectory, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(NO, NO, [self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block BOOL coordinatorExecuted = NO;
        __block BOOL isDirectory = NO;
        __block BOOL exists = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });

        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            exists = [fileManager fileExistsAtPath:newURL.path isDirectory:&isDirectory];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(exists, isDirectory, error);
        });
    }];
}

- (void)contentsOfDirectoryAtPath:(NSString *)path completion:(void(^)(NSArray *contents, NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block(nil, [self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        __block NSArray *contents = nil;
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateReadingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            
            NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:[self fullPathForPath:path]];
            if (!dirEnum) fileManagerError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileAccessFailed userInfo:nil];
            
            NSString *filename;
            NSMutableArray *mutableContents = [[NSMutableArray alloc] init];
            while ((filename = [dirEnum nextObject])) {
                if ([@[@".DS_Store", @".", @".."] containsObject:filename]) continue;
                
                ICACloudFile *file = [ICACloudFile new];
                file.name = filename;
                file.path = [path stringByAppendingPathComponent:filename];;
                file.fileAttributes = [dirEnum.fileAttributes copy];
                [mutableContents addObject:file];
                
                if ([dirEnum.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) {
                    [dirEnum skipDescendants];
                }
            }
            
            if (!fileManagerError) contents = mutableContents;
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(contents, error);
        });
    }];

}

- (void)createDirectoryAtPath:(NSString *)path completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateWritingItemAtURL:url options:0 error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager createDirectoryAtPath:newURL.path withIntermediateDirectories:YES attributes:nil error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (void)removeItemAtPath:(NSString *)path completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *url = [NSURL fileURLWithPath:[self fullPathForPath:path]];
        [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForDeleting error:&fileCoordinatorError byAccessor:^(NSURL *newURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (NSString *)temporaryDirectory
{
    static NSString *tempDir = nil;
    if (!tempDir) {
        tempDir = [NSTemporaryDirectory() stringByAppendingString:@"ICACloudTempFiles"];
        BOOL isDir;
        if (![fileManager fileExistsAtPath:tempDir isDirectory:&isDir] || !isDir) {
            NSError *error;
            [fileManager removeItemAtPath:tempDir error:NULL];
            if (![fileManager createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:&error]) {
                tempDir = nil;
                NSLog(@"Error creating temp dir for ICACloud: %@", error);
            }
        }
    }
    return tempDir;
}

- (void)uploadData:(NSData *)data toPath:(NSString *)toPath completion:(void(^)(NSError *error))completion
{
    NSString *tempFile = [[self temporaryDirectory] stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [data writeToFile:tempFile atomically:NO];
    [self uploadLocalFile:tempFile toPath:toPath completion:^(NSError *error) {
        [fileManager removeItemAtPath:tempFile error:NULL];
        if (completion) completion(error);
    }];
}

- (void)uploadLocalFile:(NSString *)fromPath toPath:(NSString *)toPath completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;

        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *fromURL = [NSURL fileURLWithPath:fromPath];
        NSURL *toURL = [NSURL fileURLWithPath:[self fullPathForPath:toPath]];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&fileCoordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

- (void)downloadDataFromPath:(NSString *)fromPath completion:(void(^)(NSData *data, NSError *error))completion
{
    NSString *tempFile = [[self temporaryDirectory] stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    [self downloadFromPath:fromPath toLocalFile:tempFile completion:^(NSError *error) {
        NSData *data = nil;
        if (!error) data = [NSData dataWithContentsOfFile:tempFile];
        [fileManager removeItemAtPath:tempFile error:NULL];
        if (completion) completion(data, error);
    }];
}


- (void)downloadFromPath:(NSString *)fromPath toLocalFile:(NSString *)toPath completion:(void(^)(NSError *error))block
{
    [operationQueue addOperationWithBlock:^{
        if (!self.isConnected) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (block) block([self notConnectedError]);
            });
            return;
        }
        
        NSError *fileCoordinatorError = nil;
        __block NSError *timeoutError = nil;
        __block NSError *fileManagerError = nil;
        __block BOOL coordinatorExecuted = NO;
        
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];

        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, ICAFileCoordinatorTimeOut * NSEC_PER_SEC);
        dispatch_after(popTime, timeOutQueue, ^{
            if (!coordinatorExecuted) {
                [coordinator cancel];
                timeoutError = [NSError errorWithDomain:ICAErrorDomain code:ICAErrorCodeFileCoordinatorTimedOut userInfo:nil];
            }
        });
        
        NSURL *fromURL = [NSURL fileURLWithPath:[self fullPathForPath:fromPath]];
        NSURL *toURL = [NSURL fileURLWithPath:toPath];
        [coordinator coordinateReadingItemAtURL:fromURL options:0 writingItemAtURL:toURL options:NSFileCoordinatorWritingForReplacing error:&fileCoordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            dispatch_sync(timeOutQueue, ^{ coordinatorExecuted = YES; });
            if (timeoutError) return;
            [fileManager removeItemAtPath:newWritingURL.path error:NULL];
            [fileManager copyItemAtPath:newReadingURL.path toPath:newWritingURL.path error:&fileManagerError];
        }];
        
        NSError *error = fileCoordinatorError ? : timeoutError ? : fileManagerError ? : nil;
        error = [self specializedErrorForCocoaError:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (block) block(error);
        });
    }];
}

@end
