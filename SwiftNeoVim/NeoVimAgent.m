/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

#import "NeoVimAgent.h"
#import "NeoVimMsgIds.h"
#import "NeoVimUiBridgeProtocol.h"
#import "Logger.h"
#import "NeoVimBuffer.h"


static const double qTimeout = 10;

#define data_to_array(type)                                               \
static type *data_to_ ## type ## _array(NSData *data, NSUInteger count) { \
  NSUInteger length = count * sizeof( type );                             \
  if (data.length != length) {                                            \
    return NULL;                                                          \
  }                                                                       \
  return ( type *) data.bytes;                                            \
}

data_to_array(int)
data_to_array(bool)
data_to_array(CellAttributes)

@interface NeoVimAgent ()

- (void)handleMessageWithId:(SInt32)msgid data:(NSData *)data;

@end


static CFDataRef local_server_callback(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
  @autoreleasepool {
    NeoVimAgent *agent = (__bridge NeoVimAgent *) info;
    [agent handleMessageWithId:msgid data:(__bridge NSData *) (data)];
  }

  return NULL;
}


@implementation NeoVimAgent {
  NSString *_uuid;

  CFMessagePortRef _remoteServerPort;

  CFMessagePortRef _localServerPort;
  NSThread *_localServerThread;
  CFRunLoopRef _localServerRunLoop;

  NSTask *_neoVimServerTask;

  bool _neoVimIsReady;
  bool _isInitErrorPresent;

  NSUInteger _requestResponseId;
  NSMutableDictionary *_requestResponseConditions;
  NSMutableDictionary *_requestResponses;
}

- (instancetype)initWithUuid:(NSString *)uuid {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  _uuid = uuid;
  _neoVimIsReady = NO;
  _isInitErrorPresent = NO;

  _requestResponseId = 0;
  _requestResponseConditions = [NSMutableDictionary new];
  _requestResponses = [NSMutableDictionary new];

  return self;
}

// We cannot use -dealloc for this since -dealloc is not called until the run loop in the thread stops.
- (void)quit {
  // Wait till we get the response from the server.
  // If we don't wait here, then the NSTask.terminate msg below could get caught by neovim which causes a warning log.
  [self sendMessageWithId:NeoVimAgentMsgIdQuit data:nil expectsReply:YES];

  if (CFMessagePortIsValid(_remoteServerPort)) {
    CFMessagePortInvalidate(_remoteServerPort);
  }
  CFRelease(_remoteServerPort);

  if (CFMessagePortIsValid(_localServerPort)) {
    CFMessagePortInvalidate(_localServerPort);
  }
  CFRelease(_localServerPort);

  CFRunLoopStop(_localServerRunLoop);
  [_localServerThread cancel];

  // Just to be sure...
  [_neoVimServerTask interrupt];
  [_neoVimServerTask terminate];
}

- (void)launchNeoVimUsingLoginShell {
  NSString *shellPath = [NSProcessInfo processInfo].environment[@"SHELL"];
  if (shellPath == nil) {
    shellPath = @"/bin/bash";
  }

  NSMutableArray *shellArgs = [NSMutableArray new];
  if (![shellPath.lastPathComponent isEqualToString:@"tcsh"]) {
    [shellArgs addObject:@"-l"];
  }
  [shellArgs addObjectsFromArray:@[
      @"-c",
      [NSString stringWithFormat:@"eval \"%@ %@ %@\"",
                                 [self neoVimServerExecutablePath],
                                 [self localServerName],
                                 [self remoteServerName]]
  ]];

  _neoVimServerTask = [[NSTask alloc] init];
  _neoVimServerTask.currentDirectoryPath = NSHomeDirectory();
  _neoVimServerTask.launchPath = shellPath;
  _neoVimServerTask.arguments = shellArgs;
  [_neoVimServerTask launch];
}

- (bool)runLocalServerAndNeoVim {
  _localServerThread = [[NSThread alloc] initWithTarget:self selector:@selector(runLocalServer) object:nil];
  [_localServerThread start];

  [self launchNeoVimUsingLoginShell];

  // Wait until neovim is ready (max. 10s).
  NSDate *deadline = [[NSDate date] dateByAddingTimeInterval:qTimeout];
  while (!_neoVimIsReady
      && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline]);

  return !_isInitErrorPresent;
}

- (void)vimCommand:(NSString *)string {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  [self sendMessageWithId:NeoVimAgentMsgIdCommand data:data expectsReply:NO];
}

- (NSString *)vimCommandOutput:(NSString *)string {
  NSUInteger reqId = _requestResponseId;
  _requestResponseId++;

  NSCondition *condition = [NSCondition new];
  _requestResponseConditions[@(reqId)] = condition;

  NSMutableData *data = [[NSMutableData alloc] initWithBytes:&reqId length:sizeof(NSUInteger)];
  [data appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];
  [self sendMessageWithId:NeoVimAgentMsgIdCommandOutput data:data expectsReply:NO];

  NSDate *deadline = [[NSDate date] dateByAddingTimeInterval:qTimeout];
  [condition lock];
  while (_requestResponses[@(reqId)] == nil) {
    [condition waitUntilDate:deadline];
  }
  [condition unlock];
  [_requestResponseConditions removeObjectForKey:@(reqId)];

  NSString *result = _requestResponses[@(reqId)];
  [_requestResponses removeObjectForKey:@(reqId)];

  return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)vimInput:(NSString *)string {
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
  [self sendMessageWithId:NeoVimAgentMsgIdInput data:data expectsReply:NO];
}

- (void)vimInputMarkedText:(NSString *_Nonnull)markedText {
  NSData *data = [markedText dataUsingEncoding:NSUTF8StringEncoding];
  [self sendMessageWithId:NeoVimAgentMsgIdInputMarked data:data expectsReply:NO];
}

- (void)deleteCharacters:(NSInteger)count {
  NSData *data = [[NSData alloc] initWithBytes:&count length:sizeof(NSInteger)];
  [self sendMessageWithId:NeoVimAgentMsgIdDelete data:data expectsReply:NO];
}

- (void)resizeToWidth:(int)width height:(int)height {
  int values[] = { width, height };
  NSData *data = [[NSData alloc] initWithBytes:values length:(2 * sizeof(int))];
  [self sendMessageWithId:NeoVimAgentMsgIdResize data:data expectsReply:NO];
}

- (bool)hasDirtyDocs {
  NSData *response = [self sendMessageWithId:NeoVimAgentMsgIdGetDirtyDocs data:nil expectsReply:YES];
  if (response == nil) {
    log4Warn("The response for the msg %lu was nil.", NeoVimAgentMsgIdGetDirtyDocs);
    return YES;
  }
  
  bool *values = data_to_bool_array(response, 1);
  return values[0];
}

- (NSString *)escapedFileName:(NSString *)fileName {
  return [self escapedFileNames:@[ fileName ]][0];
}

- (NSArray <NSString *>*)escapedFileNames:(NSArray <NSString *>*)fileNames {
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:fileNames];
  NSData *response = [self sendMessageWithId:NeoVimAgentMsgIdGetEscapeFileNames data:data expectsReply:YES];
  if (response == nil) {
    log4Warn("The response for the msg %lu was nil.", NeoVimAgentMsgIdGetEscapeFileNames);
    return @[];
  }

  return [NSKeyedUnarchiver unarchiveObjectWithData:response];
}

- (NSArray <NeoVimBuffer *> *)buffers {
  NSData *response = [self sendMessageWithId:NeoVimAgentMsgIdGetBuffers data:nil expectsReply:YES];
  if (response == nil) {
    log4Warn("The response for the msg %lu was nil.", NeoVimAgentMsgIdGetBuffers);
    return @[];
  }

  return [NSKeyedUnarchiver unarchiveObjectWithData:response];
}

- (void)runLocalServer {
  @autoreleasepool {
    CFMessagePortContext localContext = {
        .version = 0,
        .info = (__bridge void *) self,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL
    };

    unsigned char shouldFreeLocalServer = false;
    _localServerPort = CFMessagePortCreateLocal(
        kCFAllocatorDefault,
        (__bridge CFStringRef) [self localServerName],
        local_server_callback,
        &localContext,
        &shouldFreeLocalServer
    );

    // FIXME: handle shouldFreeLocalServer = true
  }

  _localServerRunLoop = CFRunLoopGetCurrent();
  CFRunLoopSourceRef runLoopSrc = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, _localServerPort, 0);
  CFRunLoopAddSource(_localServerRunLoop, runLoopSrc, kCFRunLoopCommonModes);
  CFRelease(runLoopSrc);
  CFRunLoopRun();
}

- (void)establishNeoVimConnection {
  _remoteServerPort = CFMessagePortCreateRemote(
      kCFAllocatorDefault,
      (__bridge CFStringRef) [self remoteServerName]
  );

  [self sendMessageWithId:NeoVimAgentMsgIdAgentReady data:nil expectsReply:NO];
}

- (NSData *)sendMessageWithId:(NeoVimAgentMsgId)msgid data:(NSData *)data expectsReply:(bool)expectsReply {
  if (_remoteServerPort == NULL) {
    log4Warn("Remote server is null: The msg %lu with data %@ could not be sent.", (unsigned long) msgid, data);
    return nil;
  }

  CFDataRef responseData = NULL;
  CFStringRef replyMode = expectsReply ? kCFRunLoopDefaultMode : NULL;

  SInt32 responseCode = CFMessagePortSendRequest(
      _remoteServerPort, msgid, (__bridge CFDataRef) data, qTimeout, qTimeout, replyMode, &responseData
  );

  if (responseCode != kCFMessagePortSuccess) {
    log4Warn("Got response %d for the msg %lu with data %@.", responseCode, (unsigned long) msgid, data);
    return nil;
  }

  if (responseData == NULL) {
    return nil;
  }

  NSData *result = (__bridge_transfer NSData *) responseData;
  return result;
}

- (NSString *)neoVimServerExecutablePath {
  return [[[NSBundle bundleForClass:[self class]] builtInPlugInsPath] stringByAppendingPathComponent:@"NeoVimServer"];
}

- (NSString *)localServerName {
  return [NSString stringWithFormat:@"com.qvacua.vimr.%@", _uuid];
}

- (NSString *)remoteServerName {
  return [NSString stringWithFormat:@"com.qvacua.vimr.neovim-server.%@", _uuid];
}

- (void)handleMessageWithId:(SInt32)msgid data:(NSData *)data {
  switch (msgid) {

    case NeoVimServerMsgIdServerReady:
      [self establishNeoVimConnection];
      return;

    case NeoVimServerMsgIdNeoVimReady: {
      bool *value = data_to_bool_array(data, 1);
      _isInitErrorPresent = value[0];

      _neoVimIsReady = YES;

      return;
    }

    case NeoVimServerMsgIdResize: {
      int *values = data_to_int_array(data, 2);
      if (values == nil) {
        return;
      }
      [_bridge resizeToWidth:values[0] height:values[1]];
      return;
    }

    case NeoVimServerMsgIdClear:
      [_bridge clear];
      return;

    case NeoVimServerMsgIdEolClear:
      [_bridge eolClear];
      return;

    case NeoVimServerMsgIdSetPosition: {
      int *values = data_to_int_array(data, 4);
      [_bridge gotoPosition:(Position) { .row = values[0], .column = values[1] }
               screenCursor:(Position) { .row = values[2], .column = values[3] }];
      return;
    }

    case NeoVimServerMsgIdSetMenu:
      [_bridge updateMenu];
      return;

    case NeoVimServerMsgIdBusyStart:
      [_bridge busyStart];
      return;

    case NeoVimServerMsgIdBusyStop:
      [_bridge busyStop];
      return;

    case NeoVimServerMsgIdMouseOn:
      [_bridge mouseOn];
      return;

    case NeoVimServerMsgIdMouseOff:
      [_bridge mouseOff];
      return;

    case NeoVimServerMsgIdModeChange: {
      int *values = data_to_int_array(data, 1);
      [_bridge modeChange:(Mode) values[0]];
      return;
    }

    case NeoVimServerMsgIdSetScrollRegion: {
      int *values = data_to_int_array(data, 4);
      [_bridge setScrollRegionToTop:values[0] bottom:values[1] left:values[2] right:values[3]];
      return;
    }

    case NeoVimServerMsgIdScroll: {
      int *values = data_to_int_array(data, 1);
      [_bridge scroll:values[0]];
      return;
    }

    case NeoVimServerMsgIdSetHighlightAttributes: {
      CellAttributes *values = data_to_CellAttributes_array(data, 1);
      [_bridge highlightSet:values[0]];
      return;
    }

    case NeoVimServerMsgIdPut:
    case NeoVimServerMsgIdPutMarked: {
      int *values = (int *) data.bytes;
      int row = values[0];
      int column = values[1];

      NSString *string = [[NSString alloc] initWithBytes:(values + 2)
                                                  length:data.length - 2 * sizeof(int)
                                                encoding:NSUTF8StringEncoding];

      if (msgid == NeoVimServerMsgIdPut) {
        [_bridge put:string screenCursor:(Position) { .row=row, .column=column }];
      } else {
        [_bridge putMarkedText:string screenCursor:(Position) { .row=row, .column=column }];
      }

      return;
    }

    case NeoVimServerMsgIdUnmark: {
      int *values = data_to_int_array(data, 2);
      [_bridge unmarkRow:values[0] column:values[1]];
      return;
    }

    case NeoVimServerMsgIdBell:
      [_bridge bell];
      return;

    case NeoVimServerMsgIdVisualBell:
      [_bridge visualBell];
      return;

    case NeoVimServerMsgIdFlush:
      [_bridge flush];
      return;

    case NeoVimServerMsgIdSetForeground: {
      int *values = data_to_int_array(data, 2);
      [_bridge updateForeground:values[0] dark:(bool) values[1]];
      return;
    }

    case NeoVimServerMsgIdSetBackground: {
      int *values = data_to_int_array(data, 2);
      [_bridge updateBackground:values[0] dark:(bool) values[1]];
      return;
    }

    case NeoVimServerMsgIdSetSpecial: {
      int *values = data_to_int_array(data, 2);
      [_bridge updateSpecial:values[0] dark:(bool) values[1]];
      return;
    }

    case NeoVimServerMsgIdSetTitle: {
      NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      [_bridge setTitle:string];
      return;
    }

    case NeoVimServerMsgIdSetIcon: {
      NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      [_bridge setIcon:string];
      return;
    }

    case NeoVimServerMsgIdDirtyStatusChanged: {
      bool *values = data_to_bool_array(data, 1);
      [_bridge setDirtyStatus:values[0]];
      return;
    }

    case NeoVimServerMsgIdCwdChanged:
      [_bridge cwdChanged];
      return;

    case NeoVimServerMsgIdCommandOutputResult: {
      NSUInteger *values = (NSUInteger *) data.bytes;
      NSUInteger requestId = values[0];

      NSString *output = [[NSString alloc] initWithBytes:++values
                                                  length:data.length - sizeof(NSUInteger)
                                                encoding:NSUTF8StringEncoding];

      NSCondition *condition = _requestResponseConditions[@(requestId)];
      [condition lock];
      _requestResponses[@(requestId)] = output;
      [condition broadcast];
      [condition unlock];
      return;
    }

    case NeoVimServerMsgIdStop:
      [_bridge stop];
      return;

    default:
      return;
  }
}

@end
