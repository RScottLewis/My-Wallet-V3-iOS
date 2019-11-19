//
//  AnnouncementCardViewModel.swift
//  Blockchain
//
//  Created by Daniel Huri on 26/07/2019.
//  Copyright © 2019 Blockchain Luxembourg S.A. All rights reserved.
//

import PlatformKit
import PlatformUIKit
import RxSwift
import RxRelay
import RxCocoa

/// An announcement card view model
final class AnnouncementCardViewModel {

    // MARK: - Types

    /// The style of the background
    struct Background {

        /// A blank white background. a computed property.
        static var white: Background {
            return Background(color: .white)
        }
        
        /// The background color
        let color: UIColor
        
        /// The background image
        let imageName: String?

        /// Computes the `UIImage` out of `imageName`
        var image: UIImage? {
            guard let imageName = imageName else { return nil }
            return UIImage(named: imageName)
        }
        
        init(color: UIColor = .clear, imageName: String? = nil) {
            self.imageName = imageName
            self.color = color
        }
    }
    
    /// The image descriptor
    struct Image {
        let name: String
        let size: CGSize
        
        init(name: String, size: CGSize = CGSize(width: 40, height: 40)) {
            self.name = name
            self.size = size
        }
    }
    
    /// The dismissal state of the card announcement
    enum DismissState {
        
        typealias Action = () -> Void

        /// Indicates the announcement is dismissable and the associated `Action`
        /// is should be executed upon dismissal
        case dismissible(Action)
        
        /// Indicates the announcement is not dismissable. Therefore `X` button is hidden.
        case undismissible
    }
    
    // MARK: - Properties
    
    let background: Background
    let image: Image
    let title: String?
    let description: String?
    let buttons: [ButtonViewModel]
    let didAppear: () -> Void
    
    /// Returns `true` if the dismiss button should be hidden
    var isDismissButtonHidden: Bool {
        switch dismissState {
        case .undismissible:
            return true
        case .dismissible:
            return false
        }
    }
    
    /// The action associated with the announcement dismissal.
    /// Must be accessed ONLY if `dismissState` value is `.dismissible`
    var dismissAction: DismissState.Action! {
        switch dismissState {
        case .dismissible(let action):
            return action
        case .undismissible:
            recorder.error("dismiss action was accessed but not defined")
            return nil
        }
    }
    
    private let dismissState: DismissState
    private let recorder: ErrorRecording
    
    /// Upon receiving events triggers dismissal.
    /// This comes in handy when the user has performed an indirect
    /// action that should cause card dismissal.
    let dismissalRelay = PublishRelay<Void>()
    
    private var dismissal: Completable {
        return dismissalRelay
            .take(1)
            .ignoreElements()
            .observeOn(MainScheduler.instance)
    }
    
    private let disposeBag = DisposeBag()
    
    // MARK: - Setup
    
    init(background: Background = .white,
         image: Image,
         title: String? = nil,
         description: String? = nil,
         buttons: [ButtonViewModel] = [],
         dismissState: DismissState,
         recorder: ErrorRecording = CrashlyticsRecorder(),
         didAppear: @escaping () -> Void) {
        self.background = background
        self.image = image
        self.title = title
        self.description = description
        self.dismissState = dismissState
        self.buttons = buttons
        self.recorder = recorder
        self.didAppear = didAppear
        
        if let dismissAction = dismissAction {
            dismissal
                .subscribe(onCompleted: dismissAction)
                .disposed(by: disposeBag)
        }
    }
}
