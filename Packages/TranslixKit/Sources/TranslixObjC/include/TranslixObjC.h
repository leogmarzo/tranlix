#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain of the errors `TLXObjCExceptionCatcher` produces.
extern NSErrorDomain const TLXObjCExceptionErrorDomain;

/// User-info key carrying the raised exception's `name`.
extern NSErrorUserInfoKey const TLXObjCExceptionNameKey;

/// Turns a raised Objective-C exception into an `NSError`, which Swift can catch.
///
/// Swift has no `@try`, so an `NSException` raised inside a Swift frame reaches
/// `std::terminate` and aborts the process. That is not a theoretical concern here: parts of
/// AVFAudio signal programmer error by raising, and `-[AVAudioNode installTapOnBus:...]` is
/// one of them. A recording in progress is worth more than the abort is worth defending.
@interface TLXObjCExceptionCatcher : NSObject

/// Runs `body` inside `@try`/`@catch`, reporting a raised exception as an error whose
/// localized description is the exception's name and reason.
///
/// The ONLY legitimate use is wrapping a single call documented to raise. Objective-C
/// exceptions do not unwind Swift frames correctly, so `body` must contain that one call and
/// no cleanup work of its own, and whatever object raised must be discarded rather than used
/// again.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))body error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
