//
//  KYCTiersPageModel.swift
//  Blockchain
//
//  Created by AlexM on 12/11/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation
import RxSwift

struct KYCTiersPageModel {
    let header: KYCTiersHeaderViewModel
    let cells: [KYCTierCellModel]
    let disclaimer: String?
}

extension KYCTiersPageModel {
    static let demo: KYCTiersPageModel = KYCTiersPageModel(
        header: .demo,
        cells: [.demo, .demo2],
        disclaimer: nil
    )
}
