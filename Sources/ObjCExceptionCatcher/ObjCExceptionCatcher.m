#import "ObjCExceptionCatcher.h"

NSErrorDomain const LDObjCExceptionErrorDomain = @"com.minorun365.LiveDictation.ObjCException";

@implementation LDObjCException

+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:LDObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"ExceptionName": exception.name,
                                     }];
        }
        return NO;
    }
}

@end
