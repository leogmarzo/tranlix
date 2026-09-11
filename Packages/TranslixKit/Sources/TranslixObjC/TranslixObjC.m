#import "TranslixObjC.h"

NSErrorDomain const TLXObjCExceptionErrorDomain = @"com.leomarzo.tranlix.objc-exception";
NSErrorUserInfoKey const TLXObjCExceptionNameKey = @"TLXObjCExceptionName";

@implementation TLXObjCExceptionCatcher

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))body error:(NSError **)error {
    @try {
        body();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            // Both halves matter. The name says which assertion family fired; the reason is
            // the sentence AVFAudio writes, and it is the one piece of a crash like this that
            // never reaches the crash report — which is exactly why the last one could not be
            // diagnosed from the report alone.
            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: @"sin motivo";
            *error = [NSError errorWithDomain:TLXObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"%@: %@", name, reason],
                TLXObjCExceptionNameKey: name,
            }];
        }
        return NO;
    }
}

@end
