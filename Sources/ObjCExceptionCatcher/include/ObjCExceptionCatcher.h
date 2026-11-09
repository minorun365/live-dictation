#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns an Objective-C exception raised inside it into an error.
///
/// AVFAudio reports some failures by raising NSException (for example
/// `-[AVAudioPlayerNode play]` when the engine never ran an IO cycle). Swift cannot
/// catch those, so without this the whole app aborts.
@interface LDObjCException : NSObject
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
