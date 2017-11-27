//
//  ExchangeDetailView.h
//  Blockchain
//
//  Created by Maurice A. on 11/20/17.
//  Copyright © 2017 Blockchain Luxembourg S.A. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "ExchangeTrade.h"

@interface ExchangeDetailView : UIView
- (void)createPseudoTableWithTrade:(ExchangeTrade *)trade;
@end
