//
//  EZTermsAcceptanceViewController.h
//  
//
//  Created by Brian A Nooning on 5/15/26.

    #import <UIKit/UIKit.h>

    NS_ASSUME_NONNULL_BEGIN

    extern NSString *const EZTermsAcceptedVersionKey;
    extern NSString *const EZCurrentTermsVersion;

    @interface EZTermsAcceptanceViewController : UIViewController

    + (BOOL)hasUserAcceptedCurrentTerms;
    + (void)recordAcceptance;

    @end

    NS_ASSUME_NONNULL_END
