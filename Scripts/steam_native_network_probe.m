/* SPDX-License-Identifier: GPL-3.0-only */
/* Account-free public HTTPS/OS server-trust diagnostics. No Valve code,
 * credentials, cookies, user caches, Keychain queries or response-body logs. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <unistd.h>
@interface ReadyNetworkDelegate:NSObject<NSURLSessionDelegate>
@property(atomic) BOOL trustCalled;
@property(atomic) NSInteger trustCreateStatus;
@property(atomic) NSInteger trustEvaluateStatus;
@property(atomic) NSUInteger trustResult;
@end
@implementation ReadyNetworkDelegate
-(void)URLSession:(NSURLSession*)session didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge completionHandler:(void(^)(NSURLSessionAuthChallengeDisposition,NSURLCredential*))completion {
 (void)session;
 if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]){
  SecTrustRef original=challenge.protectionSpace.serverTrust;self.trustCalled=YES;
  /* Evaluate only the public remote certificate chain through the same two
   * Security APIs imported by the measured Steam image. Never accept an
   * untrusted chain or install a custom anchor/verification override. */
  CFArrayRef chain=original?SecTrustCopyCertificateChain(original):NULL;
  SecPolicyRef policy=SecPolicyCreateSSL(true,CFSTR("api.steampowered.com"));SecTrustRef own=NULL;
  OSStatus created=chain?SecTrustCreateWithCertificates(chain,policy,&own):errSecParam;
  SecTrustResultType result=kSecTrustResultInvalid;OSStatus evaluated=created==noErr?SecTrustEvaluate(own,&result):created;
  self.trustCreateStatus=created;self.trustEvaluateStatus=evaluated;self.trustResult=result;
  if(own)CFRelease(own);if(policy)CFRelease(policy);if(chain)CFRelease(chain);
  completion(NSURLSessionAuthChallengePerformDefaultHandling,nil);
 }else completion(NSURLSessionAuthChallengeRejectProtectionSpace,nil);
}
@end
int main(void){@autoreleasepool{
 NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.URLCredentialStorage=nil;configuration.HTTPShouldSetCookies=NO;configuration.connectionProxyDictionary=@{};configuration.timeoutIntervalForRequest=7;configuration.timeoutIntervalForResource=9;
 ReadyNetworkDelegate *delegate=[ReadyNetworkDelegate new];NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];dispatch_semaphore_t finished=dispatch_semaphore_create(0);__block NSDictionary *outcome=@{@"completed":@NO};
 NSURL *url=[NSURL URLWithString:@"https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets"];NSURLSessionDataTask *task=[session dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){NSMutableArray *chain=[NSMutableArray array];for(NSError *e=error;e&&chain.count<6;e=e.userInfo[NSUnderlyingErrorKey]){NSString *domain=([e.domain hasPrefix:@"NS"]||[e.domain hasPrefix:@"kCF"])?e.domain:@"other";[chain addObject:@{@"domain":domain,@"code":@(e.code)}];}@synchronized(delegate){outcome=@{@"completed":@YES,@"HTTPStatus":@([response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse*)response statusCode]:0),@"responseBytes":@(data.length),@"errors":chain};}dispatch_semaphore_signal(finished);}];
 [task resume];BOOL expired=dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,11*NSEC_PER_SEC))!=0;if(expired)[task cancel];[session invalidateAndCancel];NSDictionary *http;@synchronized(delegate){http=outcome;}
 NSDictionary *result=@{@"URLSession":http,@"URLSessionDeadlineExceeded":@(expired),@"ServerTrust":@{@"callbackReached":@(delegate.trustCalled),@"SecTrustCreateWithCertificatesStatus":@(delegate.trustCreateStatus),@"SecTrustEvaluateStatus":@(delegate.trustEvaluateStatus),@"SecTrustResult":@(delegate.trustResult)},@"ValveLoaded":@NO,@"accountUsed":@NO,@"bodyLogged":@NO};NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];write(STDOUT_FILENO,json.bytes,json.length);write(STDOUT_FILENO,"\n",1);return 0;
}}
