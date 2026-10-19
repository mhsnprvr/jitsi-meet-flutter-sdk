/*
 * Copyright @ 2026-present 8x8, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Hands the frames of a WebRTC video track to a host app renderer, outside of the React Native UI.
 * Tracks are identified the way react-native-webrtc does: `pcId` -1 is a local track.
 */
@interface PodiumVideoTap : NSObject

/**
 * Attaches `renderer`, an `RTCVideoRenderer`, to the track. `completion` is called on the main
 * queue with whether the track was found. A renderer is attached to at most one track at a time.
 */
+ (void)addRenderer:(id)renderer
              pcId:(NSInteger)pcId
           trackId:(NSString *)trackId
        completion:(void (^_Nullable)(BOOL attached))completion;

+ (void)removeRenderer:(id)renderer;

@end

NS_ASSUME_NONNULL_END
