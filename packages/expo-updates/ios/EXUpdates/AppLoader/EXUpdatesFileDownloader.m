//  Copyright © 2019 650 Industries. All rights reserved.

#import <EXUpdates/EXUpdatesCrypto.h>
#import <EXUpdates/EXUpdatesErrorRecovery.h>
#import <EXUpdates/EXUpdatesFileDownloader.h>
#import <EXUpdates/EXUpdatesSelectionPolicies.h>
#import <EXUpdates/EXUpdatesMultipartStreamReader.h>

NS_ASSUME_NONNULL_BEGIN

NSString * const EXUpdatesFileDownloaderErrorDomain = @"EXUpdatesFileDownloader";
NSTimeInterval const EXUpdatesDefaultTimeoutInterval = 60;

@interface EXUpdatesFileDownloader () <NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionConfiguration *sessionConfiguration;
@property (nonatomic, strong) EXUpdatesConfig *config;

@end

@implementation EXUpdatesFileDownloader

- (instancetype)initWithUpdatesConfig:(EXUpdatesConfig *)updatesConfig
{
  return [self initWithUpdatesConfig:updatesConfig
             URLSessionConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
}

- (instancetype)initWithUpdatesConfig:(EXUpdatesConfig *)updatesConfig
              URLSessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration
{
  if (self = [super init]) {
    _sessionConfiguration = sessionConfiguration;
    _session = [NSURLSession sessionWithConfiguration:_sessionConfiguration delegate:self delegateQueue:nil];
    _config = updatesConfig;
  }
  return self;
}

- (void)dealloc
{
  [_session finishTasksAndInvalidate];
}

+ (dispatch_queue_t)assetFilesQueue
{
  static dispatch_queue_t theQueue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (!theQueue) {
      theQueue = dispatch_queue_create("expo.controller.AssetFilesQueue", DISPATCH_QUEUE_SERIAL);
    }
  });
  return theQueue;
}

- (void)downloadFileFromURL:(NSURL *)url
                     toPath:(NSString *)destinationPath
               extraHeaders:(NSDictionary *)extraHeaders
               successBlock:(EXUpdatesFileDownloaderSuccessBlock)successBlock
                 errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock
{
  [self downloadDataFromURL:url extraHeaders:extraHeaders successBlock:^(NSData *data, NSURLResponse *response) {
    NSError *error;
    if ([data writeToFile:destinationPath options:NSDataWritingAtomic error:&error]) {
      successBlock(data, response);
    } else {
      errorBlock([NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                     code:1002
                                 userInfo:@{
                                   NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not write to path %@: %@", destinationPath, error.localizedDescription],
                                   NSUnderlyingErrorKey: error
                                 }
                  ]);
    }
  } errorBlock:errorBlock];
}

- (NSURLRequest *)createManifestRequestWithURL:(NSURL *)url extraHeaders:(nullable NSDictionary *)extraHeaders
{
  NSURLRequestCachePolicy cachePolicy = _sessionConfiguration ? _sessionConfiguration.requestCachePolicy : NSURLRequestUseProtocolCachePolicy;

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:cachePolicy timeoutInterval:EXUpdatesDefaultTimeoutInterval];
  [self _setManifestHTTPHeaderFields:request withExtraHeaders:extraHeaders];

  return request;
}

- (NSURLRequest *)createGenericRequestWithURL:(NSURL *)url extraHeaders:(NSDictionary *)extraHeaders
{
  // pass any custom cache policy onto this specific request
  NSURLRequestCachePolicy cachePolicy = _sessionConfiguration ? _sessionConfiguration.requestCachePolicy : NSURLRequestUseProtocolCachePolicy;

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:cachePolicy timeoutInterval:EXUpdatesDefaultTimeoutInterval];
  [self _setHTTPHeaderFields:request extraHeaders:extraHeaders];
  
  return request;
}

- (void)parseManifestResponse:(NSHTTPURLResponse *)httpResponse
                     withData:(NSData *)data
                     database:(EXUpdatesDatabase *)database
                 successBlock:(EXUpdatesFileDownloaderManifestSuccessBlock)successBlock
                   errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock {
  NSDictionary *headerDictionary = [httpResponse allHeaderFields];
  id contentTypeRaw = headerDictionary[@"content-type"];
  NSString *contentType;
  if (contentTypeRaw != nil && [contentTypeRaw isKindOfClass:[NSString class]]) {
    contentType = contentTypeRaw;
  } else {
    contentType = @"";
  }
  
  NSString *multipartPattern = @"multipart/.*boundary=\"?([^\"]+)\"?";
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:multipartPattern
                                                                         options:0
                                                                           error:nil];
  NSTextCheckingResult *match = [regex firstMatchInString:contentType
                                                  options:0
                                                    range:NSMakeRange(0, contentType.length)];
  if (match != nil) {
    NSString *boundary = [contentType substringWithRange:[match rangeAtIndex:1]];
    return [self parseMultipartManifestResponse:httpResponse
                                       withData:data
                                       database:database
                                       boundary:boundary
                                   successBlock:successBlock
                                     errorBlock:errorBlock];
  } else {
    return [self parseManifestBodyData:data
                      headerDictionary:[httpResponse allHeaderFields]
                            extensions:[NSDictionary new]
                              database:database
                          successBlock:successBlock
                            errorBlock:errorBlock];
  }
}

- (void)parseMultipartManifestResponse:(NSHTTPURLResponse *)httpResponse
                              withData:(NSData *)data
                              database:(EXUpdatesDatabase *)database
                              boundary:(NSString *)boundary
                          successBlock:(EXUpdatesFileDownloaderManifestSuccessBlock)successBlock
                            errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock {
  NSInputStream *inputStream = [[NSInputStream alloc] initWithData:data];
  EXUpdatesMultipartStreamReader *reader = [[EXUpdatesMultipartStreamReader alloc] initWithInputStream:inputStream boundary:boundary];

  __block NSDictionary *manifestHeaders = nil;
  __block NSData *manifestData = nil;
  __block NSData *extensionsData = nil;
  
  NSString *contentDispositionNameFieldPattern = @".*name=\"?([^\"]+)\"?";
  NSRegularExpression *contentDispositionNameFieldRegex = [NSRegularExpression regularExpressionWithPattern:contentDispositionNameFieldPattern
                                                                                                    options:0
                                                                                                      error:nil];

  BOOL completed = [reader readAllPartsWithCompletionCallback:^(NSDictionary *headers, NSData *content, BOOL done) {
    id contentDispositionRaw;
    for (NSString *key in headers) {
      if ([key caseInsensitiveCompare: @"content-disposition"] == NSOrderedSame) {
        contentDispositionRaw = headers[key];
      }
    }
    
    NSString *contentDisposition = nil;
    if (contentDispositionRaw != nil && [contentDispositionRaw isKindOfClass:[NSString class]]) {
      contentDisposition = contentDispositionRaw;
    }
    
    if (contentDisposition != nil) {
      NSTextCheckingResult *contentDispositionNameFieldMatch = [contentDispositionNameFieldRegex firstMatchInString:contentDisposition
                                                                                                            options:0
                                                                                                              range:NSMakeRange(0, contentDisposition.length)];
      if (contentDispositionNameFieldMatch != nil) {
        NSString *nameFieldValue = [contentDisposition substringWithRange:[contentDispositionNameFieldMatch rangeAtIndex:1]];
        if ([nameFieldValue isEqualToString:@"manifest"]) {
          manifestHeaders = headers;
          manifestData = content;
        } else if ([nameFieldValue isEqualToString:@"extensions"]) {
          extensionsData = content;
        }
      }
    }
  } progressCallback:^(NSDictionary *headers, NSNumber *loaded, NSNumber *total) {}];
  
  if (!completed) {
    NSError *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                         code:1044
                                     userInfo:@{
      NSLocalizedDescriptionKey: @"Could not read multipart manifest response",
    }];
    errorBlock(error);
    return;
  }
  
  if (manifestHeaders == nil || manifestData == nil) {
    NSError *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                         code:1045
                                     userInfo:@{
      NSLocalizedDescriptionKey: @"Multipart manifest response missing manifest part",
    }];
    errorBlock(error);
    return;
  }
  
  NSDictionary *extensions;
  if (extensionsData != nil) {
    NSError *extensionsParsingError;
    id parsedExtensions = [NSJSONSerialization JSONObjectWithData:extensionsData options:kNilOptions error:&extensionsParsingError];
    if (extensionsParsingError) {
      errorBlock(extensionsParsingError);
      return;
    }
    
    if ([parsedExtensions isKindOfClass:[NSDictionary class]]) {
      extensions = parsedExtensions;
    } else {
      NSError *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                           code:1046
                                       userInfo:@{
        NSLocalizedDescriptionKey: @"Failed to parse multipart manifest extensions",
      }];
      errorBlock(error);
      return;
    }
  }

  return [self parseManifestBodyData:manifestData
                    headerDictionary:manifestHeaders
                          extensions:extensions
                            database:database
                        successBlock:successBlock
                          errorBlock:errorBlock];
}

- (void)parseManifestBodyData:(NSData *)data
             headerDictionary:(NSDictionary *)headerDictionary
                   extensions:(NSDictionary *)extensions
                     database:(EXUpdatesDatabase *)database
                 successBlock:(EXUpdatesFileDownloaderManifestSuccessBlock)successBlock
                   errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock {
  id headerSignature = headerDictionary[@"expo-manifest-signature"];
  
  NSError *err;
  id parsedJson = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&err];
  if (err) {
    errorBlock(err);
    return;
  }

  NSDictionary *updateResponseDictionary = [self _extractUpdateResponseDictionary:parsedJson error:&err];
  if (err) {
    errorBlock(err);
    return;
  }

  id bodyManifestString = updateResponseDictionary[@"manifestString"];
  id bodySignature = updateResponseDictionary[@"signature"];
  BOOL isSignatureInBody = bodyManifestString != nil && bodySignature != nil;

  id signature = isSignatureInBody ? bodySignature : headerSignature;
  id manifestString = isSignatureInBody ? bodyManifestString : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
  // XDL serves unsigned manifests with the `signature` key set to "UNSIGNED".
  // We should treat these manifests as unsigned rather than signed with an invalid signature.
  BOOL isUnsignedFromXDL = [(NSString *)signature isEqualToString:@"UNSIGNED"];

  if (![manifestString isKindOfClass:[NSString class]]) {
    errorBlock([NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                   code:1041
                               userInfo:@{
                                 NSLocalizedDescriptionKey: @"manifestString should be a string",
                               }
                ]);
    return;
  }
  NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[(NSString *)manifestString dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&err];
  if (err || !manifest || ![manifest isKindOfClass:[NSDictionary class]]) {
    errorBlock([NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                   code:1042
                               userInfo:@{
                                 NSLocalizedDescriptionKey: @"manifest should be a valid JSON object",
                               }
                ]);
    return;
  }
  NSMutableDictionary *mutableManifest = [manifest mutableCopy];
    
  if (signature != nil && !isUnsignedFromXDL) {
    if (![signature isKindOfClass:[NSString class]]) {
      errorBlock([NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                     code:1043
                                 userInfo:@{
                                   NSLocalizedDescriptionKey: @"signature should be a string",
                                 }
                  ]);
      return;
    }
    [EXUpdatesCrypto verifySignatureWithData:(NSString *)manifestString
                                   signature:(NSString *)signature
                                      config:self->_config
                                successBlock:^(BOOL isValid) {
                                                if (isValid) {
                                                  [self _createUpdateWithManifest:mutableManifest
                                                                          headers:headerDictionary
                                                                       extensions:extensions
                                                                         database:database
                                                                       isVerified:YES
                                                                     successBlock:successBlock
                                                                       errorBlock:errorBlock];
                                                } else {
                                                  NSError *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain code:1003 userInfo:@{NSLocalizedDescriptionKey: @"Manifest verification failed"}];
                                                  errorBlock(error);
                                                }
                                              }
                                  errorBlock:^(NSError *error) {
                                                errorBlock(error);
                                              }
    ];
  } else {
    [self _createUpdateWithManifest:mutableManifest
                            headers:headerDictionary
                         extensions:extensions
                           database:database
                         isVerified:NO
                       successBlock:successBlock
                         errorBlock:errorBlock];
  }
}

- (void)downloadManifestFromURL:(NSURL *)url
                   withDatabase:(EXUpdatesDatabase *)database
                   extraHeaders:(nullable NSDictionary *)extraHeaders
                   successBlock:(EXUpdatesFileDownloaderManifestSuccessBlock)successBlock
                     errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock
{
  NSURLRequest *request = [self createManifestRequestWithURL:url extraHeaders:extraHeaders];
  [self _downloadDataWithRequest:request successBlock:^(NSData *data, NSURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
      errorBlock([NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                     code:1040
                                 userInfo:@{
                                   NSLocalizedDescriptionKey: @"response must be a NSHTTPURLResponse",
                                 }
                  ]);
      return;
    }
    return [self parseManifestResponse:(NSHTTPURLResponse *)response
                              withData:data
                              database:database
                          successBlock:successBlock
                            errorBlock:errorBlock];
  } errorBlock:errorBlock];
}

- (void)_createUpdateWithManifest:(NSMutableDictionary *)mutableManifest
                          headers:(NSDictionary *)headers
                       extensions:(NSDictionary *)extensions
                         database:(EXUpdatesDatabase *)database
                       isVerified:(BOOL)isVerified
                     successBlock:(EXUpdatesFileDownloaderManifestSuccessBlock)successBlock
                       errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock
{
  if (_config.expectsSignedManifest) {
    // There are a few cases in Expo Go where we still want to use the unsigned manifest anyway, so don't mark it as unverified.
    mutableManifest[@"isVerified"] = @(isVerified);
  }

  NSError *error;
  EXUpdatesUpdate *update;
  @try {
    update = [EXUpdatesUpdate updateWithManifest:mutableManifest.copy
                                         headers:headers
                                      extensions:extensions
                                          config:_config
                                        database:database
                                           error:&error];
  }
  @catch (NSException *exception) {
    // Catch any assertions related to parsing the manifest JSON,
    // this will ensure invalid manifests can be easily debugged.
    // For example, this will catch nullish sdkVersion assertions.
    error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                code:1022
                            userInfo:@{NSLocalizedDescriptionKey: [@"Failed to parse manifest: " stringByAppendingString:exception.reason] }];
  }
  
  if (error) {
    errorBlock(error);
    return;
  }

  if (![EXUpdatesSelectionPolicies doesUpdate:update matchFilters:update.manifestFilters]) {
    NSError *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain
                                         code:1021
                                     userInfo:@{NSLocalizedDescriptionKey: @"Downloaded manifest is invalid; provides filters that do not match its content"}];
    errorBlock(error);
  } else {
    successBlock(update);
  }
}

- (void)downloadDataFromURL:(NSURL *)url
               extraHeaders:(NSDictionary *)extraHeaders
               successBlock:(EXUpdatesFileDownloaderSuccessBlock)successBlock
                 errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock
{
  NSURLRequest *request = [self createGenericRequestWithURL:url extraHeaders:extraHeaders];
  [self _downloadDataWithRequest:request successBlock:successBlock errorBlock:errorBlock];
}

- (void)_downloadDataWithRequest:(NSURLRequest *)request
                    successBlock:(EXUpdatesFileDownloaderSuccessBlock)successBlock
                      errorBlock:(EXUpdatesFileDownloaderErrorBlock)errorBlock
{
  NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        NSStringEncoding encoding = [self _encodingFromResponse:response];
        NSString *body = [[NSString alloc] initWithData:data encoding:encoding];
        error = [self _errorFromResponse:httpResponse body:body];
      }
    }

    if (error) {
      errorBlock(error);
    } else {
      successBlock(data, response);
    }
  }];
  [task resume];
}

- (nullable NSDictionary *)_extractUpdateResponseDictionary:(id)parsedJson error:(NSError **)error
{
  if ([parsedJson isKindOfClass:[NSDictionary class]]) {
    return (NSDictionary *)parsedJson;
  } else if ([parsedJson isKindOfClass:[NSArray class]]) {
    // TODO: either add support for runtimeVersion or deprecate multi-manifests
    for (id providedManifest in (NSArray *)parsedJson) {
      if ([providedManifest isKindOfClass:[NSDictionary class]] && providedManifest[@"sdkVersion"]){
        NSString *sdkVersion = providedManifest[@"sdkVersion"];
        NSArray<NSString *> *supportedSdkVersions = [_config.sdkVersion componentsSeparatedByString:@","];
        if ([supportedSdkVersions containsObject:sdkVersion]){
          return providedManifest;
        }
      }
    }
  }

  if (error) {
    *error = [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain code:1009 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No compatible update found at %@. Only %@ are supported.", _config.updateUrl.absoluteString, _config.sdkVersion]}];
  }
  return nil;
}

- (void)_setHTTPHeaderFields:(NSMutableURLRequest *)request
                extraHeaders:(NSDictionary *)extraHeaders
{
  for (NSString *key in extraHeaders) {
    [request setValue:extraHeaders[key] forHTTPHeaderField:key];
  }
  
  [request setValue:@"ios" forHTTPHeaderField:@"Expo-Platform"];
  [request setValue:@"1" forHTTPHeaderField:@"Expo-API-Version"];
  [request setValue:@"BARE" forHTTPHeaderField:@"Expo-Updates-Environment"];

  for (NSString *key in _config.requestHeaders) {
    [request setValue:_config.requestHeaders[key] forHTTPHeaderField:key];
  }
}

- (void)_setManifestHTTPHeaderFields:(NSMutableURLRequest *)request withExtraHeaders:(nullable NSDictionary *)extraHeaders
{
  // apply extra headers before anything else, so they don't override preset headers
  if (extraHeaders) {
    for (NSString *key in extraHeaders) {
      id value = extraHeaders[key];
      if ([value isKindOfClass:[NSString class]]) {
        [request setValue:value forHTTPHeaderField:key];
      } else if ([value isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)(value)) == CFBooleanGetTypeID()) {
          [request setValue:((NSNumber *)value).boolValue ? @"true" : @"false" forHTTPHeaderField:key];
        } else {
          [request setValue:((NSNumber *)value).stringValue forHTTPHeaderField:key];
        }
      } else {
        [request setValue:[(NSObject *)value description] forHTTPHeaderField:key];
      }
    }
  }

  [request setValue:@"application/expo+json,application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"ios" forHTTPHeaderField:@"Expo-Platform"];
  [request setValue:@"1" forHTTPHeaderField:@"Expo-API-Version"];
  [request setValue:@"BARE" forHTTPHeaderField:@"Expo-Updates-Environment"];
  [request setValue:@"true" forHTTPHeaderField:@"Expo-JSON-Error"];
  [request setValue:(_config.expectsSignedManifest ? @"true" : @"false") forHTTPHeaderField:@"Expo-Accept-Signature"];
  [request setValue:_config.releaseChannel forHTTPHeaderField:@"Expo-Release-Channel"];

  NSString *runtimeVersion = _config.runtimeVersion;
  if (runtimeVersion) {
    [request setValue:runtimeVersion forHTTPHeaderField:@"Expo-Runtime-Version"];
  } else {
    [request setValue:_config.sdkVersion forHTTPHeaderField:@"Expo-SDK-Version"];
  }

  NSString *previousFatalError = [EXUpdatesErrorRecovery consumeErrorLog];
  if (previousFatalError) {
    // some servers can have max length restrictions for headers,
    // so we restrict the length of the string to 1024 characters --
    // this should satisfy the requirements of most servers
    if ([previousFatalError length] > 1024) {
      previousFatalError = [previousFatalError substringToIndex:1024];
    }
    [request setValue:previousFatalError forHTTPHeaderField:@"Expo-Fatal-Error"];
  }

  for (NSString *key in _config.requestHeaders) {
    [request setValue:_config.requestHeaders[key] forHTTPHeaderField:key];
  }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler
{
  completionHandler(request);
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask willCacheResponse:(NSCachedURLResponse *)proposedResponse completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
  completionHandler(proposedResponse);
}

#pragma mark - Parsing the response

- (NSStringEncoding)_encodingFromResponse:(NSURLResponse *)response
{
  if (response.textEncodingName) {
    CFStringRef cfEncodingName = (__bridge CFStringRef)response.textEncodingName;
    CFStringEncoding cfEncoding = CFStringConvertIANACharSetNameToEncoding(cfEncodingName);
    if (cfEncoding != kCFStringEncodingInvalidId) {
      return CFStringConvertEncodingToNSStringEncoding(cfEncoding);
    }
  }
  // Default to UTF-8
  return NSUTF8StringEncoding;
}

- (NSError *)_errorFromResponse:(NSHTTPURLResponse *)response body:(NSString *)body
{
  NSDictionary *userInfo = @{
                             NSLocalizedDescriptionKey: body,
                             };
  return [NSError errorWithDomain:EXUpdatesFileDownloaderErrorDomain code:response.statusCode userInfo:userInfo];
}

@end

NS_ASSUME_NONNULL_END
