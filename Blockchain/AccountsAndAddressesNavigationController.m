//
//  AccountsAndAddressesNavigationController.m
//  Blockchain
//
//  Created by Kevin Wu on 1/12/16.
//  Copyright © 2016 Blockchain Luxembourg S.A. All rights reserved.
//

#import "AccountsAndAddressesNavigationController.h"
#import "AccountsAndAddressesViewController.h"
#import "AccountsAndAddressesDetailViewController.h"
#import "RootService.h"
#import "PrivateKeyReader.h"
#import "SendBitcoinViewController.h"
#import "UIView+ChangeFrameAttribute.h"
#import "Blockchain-Swift.h"

@interface AccountsAndAddressesNavigationController () <AssetSelectorViewDelegate>
@property (nonatomic, readwrite) AssetSelectorView *assetSelectorView;
@property (nonatomic) UIView *topBar;
@property (nonatomic) BOOL isOpeningSelector;
@end

@implementation AccountsAndAddressesNavigationController

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.frame = CGRectMake(0, 0, [UIApplication sharedApplication].keyWindow.frame.size.width, [UIApplication sharedApplication].keyWindow.frame.size.height);
    
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT)];
    topBar.backgroundColor = COLOR_BLOCKCHAIN_BLUE;
    [self.view addSubview:topBar];
    self.topBar = topBar;
    
    UILabel *headerLabel = [[UILabel alloc] initWithFrame:FRAME_HEADER_LABEL];
    headerLabel.font = [UIFont fontWithName:FONT_MONTSERRAT_REGULAR size:FONT_SIZE_TOP_BAR_TEXT];
    headerLabel.textColor = [UIColor whiteColor];
    headerLabel.textAlignment = NSTextAlignmentCenter;
    headerLabel.adjustsFontSizeToFitWidth = YES;
    headerLabel.center = CGPointMake(topBar.center.x, headerLabel.center.y);
    [topBar addSubview:headerLabel];
    self.headerLabel = headerLabel;
    
    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeCustom];
    backButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    backButton.imageEdgeInsets = IMAGE_EDGE_INSETS_BACK_BUTTON_CHEVRON;
    [backButton.titleLabel setFont:[UIFont systemFontOfSize:FONT_SIZE_MEDIUM]];
    [backButton setImage:[UIImage imageNamed:@"back_chevron_icon"] forState:UIControlStateNormal];
    [backButton setTitleColor:[UIColor colorWithWhite:0.56 alpha:1.0] forState:UIControlStateHighlighted];
    [backButton addTarget:self action:@selector(backButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [topBar addSubview:backButton];
    self.backButton = backButton;
#ifdef ENABLE_TRANSFER_FUNDS
    UIButton *warningButton = [UIButton buttonWithType:UIButtonTypeCustom];
    warningButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    warningButton.imageEdgeInsets = UIEdgeInsetsMake(0, 4, 0, 0);
    [warningButton.titleLabel setFont:[UIFont systemFontOfSize:FONT_SIZE_MEDIUM]];
    [warningButton setImage:[UIImage imageNamed:@"warning"] forState:UIControlStateNormal];
    [warningButton addTarget:self action:@selector(transferAllFundsWarningClicked) forControlEvents:UIControlEventTouchUpInside];
    [topBar addSubview:warningButton];
    warningButton.hidden = YES;
    self.warningButton = warningButton;
#endif

    CGFloat assetSelectorViewHorizontalPadding = 8;
    self.assetSelectorView = [[AssetSelectorView alloc] initWithFrame:CGRectMake(assetSelectorViewHorizontalPadding, headerLabel.frame.origin.y + headerLabel.frame.size.height + 8, self.view.frame.size.width - assetSelectorViewHorizontalPadding*2, ASSET_SELECTOR_ROW_HEIGHT) assets:@[[NSNumber numberWithInteger:AssetTypeBitcoin], [NSNumber numberWithInteger:AssetTypeBitcoinCash]] delegate:self];
    [topBar addSubview:self.assetSelectorView];
    
    [self setupBusyView];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    
    if (self.isOpeningSelector) return;
    
    self.warningButton.frame = CGRectMake(6, 16, 85, 51);
    
    if (self.viewControllers.count == 1 || [self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
        self.backButton.frame = CGRectMake(self.view.frame.size.width - 80, 15, 80, 51);
        self.backButton.imageEdgeInsets = IMAGE_EDGE_INSETS_CLOSE_BUTTON_X;
        self.backButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        self.backButton.center = CGPointMake(self.backButton.center.x, self.headerLabel.center.y);
        [self.backButton setImage:[UIImage imageNamed:@"close"] forState:UIControlStateNormal];
        [UIView animateWithDuration:ANIMATION_DURATION animations:^{
            [self.topBar changeHeight:DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT];
            [self.assetSelectorView show];
            [self resetAddressesViewControllerContainerFrame];
        }];
    } else {
        self.backButton.frame = FRAME_BACK_BUTTON;
        self.backButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [self.backButton setTitle:@"" forState:UIControlStateNormal];
        self.backButton.imageEdgeInsets = IMAGE_EDGE_INSETS_BACK_BUTTON_CHEVRON;
        [self.backButton setImage:[UIImage imageNamed:@"back_chevron_icon"] forState:UIControlStateNormal];
        [UIView animateWithDuration:ANIMATION_DURATION animations:^{
            [self.assetSelectorView hide];
            [self.topBar changeHeight:DEFAULT_HEADER_HEIGHT];
        }];
    }
}

- (void)reload
{
    if (![self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]] &&
        ![self.visibleViewController isMemberOfClass:[AccountsAndAddressesDetailViewController class]]) {
        [self popViewControllerAnimated:YES];
    }
    
    if (!self.view.window) {
        [self popToRootViewControllerAnimated:NO];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NOTIFICATION_KEY_RELOAD_ACCOUNTS_AND_ADDRESSES object:nil];
}

#pragma mark - Busy view

- (void)showBusyViewWithLoadingText:(NSString *)text
{
    self.busyLabel.text = text;
    [self.view bringSubviewToFront:self.busyView];
    if (self.busyView.alpha < 1.0) {
        [self.busyView fadeIn];
    }
}

- (void)updateBusyViewLoadingText:(NSString *)text
{
    if (self.busyView.alpha == 1.0) {
        [UIView animateWithDuration:ANIMATION_DURATION animations:^{
            [self.busyLabel setText:text];
        }];
    }
}

- (void)hideBusyView
{
    if (self.busyView.alpha == 1.0) {
        [self.busyView fadeOut];
    }
}

#pragma mark - UI helpers

- (void)setupBusyView
{
    BCFadeView *busyView = [[BCFadeView alloc] initWithFrame:[UIApplication sharedApplication].keyWindow.rootViewController.view.frame];
    busyView.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.5];
    UIView *textWithSpinnerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 250, 110)];
    textWithSpinnerView.backgroundColor = [UIColor whiteColor];
    [busyView addSubview:textWithSpinnerView];
    textWithSpinnerView.center = busyView.center;
    
    self.busyLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 230, 30)];
    self.busyLabel.font = [UIFont fontWithName:FONT_MONTSERRAT_REGULAR size:FONT_SIZE_SMALL_MEDIUM];
    self.busyLabel.alpha = 0.75;
    self.busyLabel.textAlignment = NSTextAlignmentCenter;
    self.busyLabel.adjustsFontSizeToFitWidth = YES;
    self.busyLabel.text = BC_STRING_LOADING_SYNCING_WALLET;
    self.busyLabel.center = CGPointMake(textWithSpinnerView.bounds.origin.x + textWithSpinnerView.bounds.size.width/2, textWithSpinnerView.bounds.origin.y + textWithSpinnerView.bounds.size.height/2 + 15);
    [textWithSpinnerView addSubview:self.busyLabel];
    
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    spinner.center = CGPointMake(textWithSpinnerView.bounds.origin.x + textWithSpinnerView.bounds.size.width/2, textWithSpinnerView.bounds.origin.y + textWithSpinnerView.bounds.size.height/2 - 15);
    [textWithSpinnerView addSubview:spinner];
    [textWithSpinnerView bringSubviewToFront:spinner];
    [spinner startAnimating];
    
    busyView.containerView = textWithSpinnerView;
    [busyView fadeOut];
    
    [self.view addSubview:busyView];
    
    [self.view bringSubviewToFront:busyView];
    
    self.busyView = busyView;
}

- (void)alertUserToTransferAllFunds:(BOOL)userClicked
{
#ifdef ENABLE_TRANSFER_FUNDS
    UIAlertController *alertToTransfer = [UIAlertController alertControllerWithTitle:BC_STRING_TRANSFER_FUNDS message:[NSString stringWithFormat:@"%@\n\n%@", BC_STRING_TRANSFER_FUNDS_DESCRIPTION_ONE, BC_STRING_TRANSFER_FUNDS_DESCRIPTION_TWO] preferredStyle:UIAlertControllerStyleAlert];
    [alertToTransfer addAction:[UIAlertAction actionWithTitle:BC_STRING_NOT_NOW style:UIAlertActionStyleCancel handler:nil]];
    [alertToTransfer addAction:[UIAlertAction actionWithTitle:BC_STRING_TRANSFER_FUNDS style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self transferAllFundsClicked];
    }]];
    
    if (!userClicked) {
        [alertToTransfer addAction:[UIAlertAction actionWithTitle:BC_STRING_DONT_SHOW_AGAIN style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:USER_DEFAULTS_KEY_HIDE_TRANSFER_ALL_FUNDS_ALERT];
        }]];
    }
    
    [self presentViewController:alertToTransfer animated:YES completion:nil];
#endif
}

#pragma mark - Transfer Funds

- (void)transferAllFundsWarningClicked
{
    [self alertUserToTransferAllFunds:YES];
}

- (void)transferAllFundsClicked
{
    [self dismissViewControllerAnimated:YES completion:^{
        [[AppCoordinator sharedInstance] closeSideMenu];
    }];
    
    [app setupTransferAllFunds];
}

#pragma mark - Navigation

- (IBAction)backButtonClicked:(UIButton *)sender
{
    if ([self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self popViewControllerAnimated:YES];
    }
}

- (void)didGenerateNewAddress
{
    if ([self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
        AccountsAndAddressesViewController *accountsAndAddressesViewController = (AccountsAndAddressesViewController *)self.visibleViewController;
        [accountsAndAddressesViewController didGenerateNewAddress];
    }
}

- (void)resetAddressesViewControllerContainerFrame
{
    if ([self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
        AccountsAndAddressesViewController *accountsAndAddressesViewController = (AccountsAndAddressesViewController *)self.visibleViewController;
        [accountsAndAddressesViewController.containerView changeYPosition:DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT];
    }
}

#pragma mark - Asset Selector View Delegate

- (void)didSelectAsset:(AssetType)assetType
{
    [UIView animateWithDuration:ANIMATION_DURATION animations:^{
        [self.topBar changeHeight:DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT];
        [self resetAddressesViewControllerContainerFrame];
    }];
    
    if ([self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
        AccountsAndAddressesViewController *accountsAndAddressesViewController = (AccountsAndAddressesViewController *)self.visibleViewController;
        accountsAndAddressesViewController.assetType = assetType;
    };
}

- (void)didOpenSelector
{
    self.isOpeningSelector = YES;

    [UIView animateWithDuration:ANIMATION_DURATION animations:^{
        [self.topBar changeHeight:DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT*self.assetSelectorView.assets.count];
        if ([self.visibleViewController isMemberOfClass:[AccountsAndAddressesViewController class]]) {
            AccountsAndAddressesViewController *accountsAndAddressesViewController = (AccountsAndAddressesViewController *)self.visibleViewController;
            [accountsAndAddressesViewController.containerView changeYPosition:DEFAULT_HEADER_HEIGHT + 8 + ASSET_SELECTOR_ROW_HEIGHT*self.assetSelectorView.assets.count];
        }
    } completion:^(BOOL finished) {
        self.isOpeningSelector = NO;
    }];
}

@end
