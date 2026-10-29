/* SPDX-License-Identifier: GPL-3.0-only */
#import <QuartzCore/QuartzCore.h>
void ReadySplashAnimationObserverStart(void);
void ReadySplashAnimationObserverStop(void);
CAAnimation * _Nullable ReadySplashRecordedAnimation(CALayer * _Nonnull layer,const char * _Nonnull key);
unsigned ReadySplashRemovalCount(CALayer * _Nonnull layer);
unsigned ReadySplashAdditionCount(CALayer * _Nonnull layer,const char * _Nonnull key);
