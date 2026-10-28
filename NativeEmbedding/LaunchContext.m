#import <Cocoa/Cocoa.h>
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 4)
      return 2;
    NSString *app = @(argv[1]), *dylib = @(argv[2]), *receipt = @(argv[3]);
    NSWorkspaceOpenConfiguration *c =
        [NSWorkspaceOpenConfiguration configuration];
    c.arguments = @[ @"--probe" ];
    c.environment = @{
      @"DYLD_INSERT_LIBRARIES" : dylib,
      @"NATIVE_EMBED_PROBE_FILE" : receipt
    };
    c.activates = NO;
    c.createsNewApplicationInstance = YES;
    __block BOOL complete = NO;
    __block int result = 0;
    [[NSWorkspace sharedWorkspace]
        openApplicationAtURL:[NSURL fileURLWithPath:app]
               configuration:c
           completionHandler:^(NSRunningApplication *a, NSError *e) {
             fprintf(stdout, "NSWORKSPACE pid=%d error=%s\n",
                     a.processIdentifier, e.description.UTF8String ?: "none");
             if (e)
               result = 3;
             complete = YES;
           }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!complete && limit.timeIntervalSinceNow > 0)
      [[NSRunLoop currentRunLoop]
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    return complete ? result : 4;
  }
}
