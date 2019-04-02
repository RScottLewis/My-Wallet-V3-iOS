//
//  ExchangeCreateInteractor.swift
//  Blockchain
//
//  Created by kevinwu on 8/28/18.
//  Copyright © 2018 Blockchain Luxembourg S.A. All rights reserved.
//

import Foundation
import RxSwift
import PlatformKit

class ExchangeCreateInteractor {

    weak var output: ExchangeCreateOutput? {
        didSet {
            // output is not set during ExchangeCreateInteractor initialization,
            // so the first update to the trading pair view is done here
            didSetModel(oldModel: nil)
        }
    }
    
    var status: ExchangeInteractorStatus {
        willSet {
            guard newValue != status else { return }
        }
        didSet {
            switch status {
            case .error:
                output?.errorReceived()
            case .inflight,
                 .unknown:
                output?.tradeValidationInFlight()
            case .valid:
                output?.errorDismissed()
            }
        }
    }

    private let disposables = CompositeDisposable()
    private var accountDisposeBag: DisposeBag = DisposeBag()
    private var tradingLimitDisposable: Disposable?
    private var repository: AssetAccountRepository = {
       return AssetAccountRepository.shared
    }()

    fileprivate let inputs: ExchangeInputsAPI
    fileprivate let markets: ExchangeMarketsAPI
    fileprivate let conversions: ExchangeConversionAPI
    fileprivate let tradeExecution: TradeExecutionAPI
    fileprivate let tradeLimitService: TradeLimitsAPI
    private(set) var model: MarketsModel? {
        didSet {
            didSetModel(oldModel: oldValue)
        }
    }

    init(dependencies: ExchangeDependencies, model: MarketsModel) {
        self.markets = dependencies.markets
        self.inputs = dependencies.inputs
        self.conversions = dependencies.conversions
        self.tradeExecution = dependencies.tradeExecution
        self.tradeLimitService = dependencies.tradeLimits
        self.model = model
        self.status = .unknown
    }

    func didSetModel(oldModel: MarketsModel?) {
        // TICKET: IOS-1287 - This should be called after user has stopped typing
        if markets.hasAuthenticated {
            updateMarketsConversion()
        }

        // Only update TradingPair in Trading Pair View if it is different
        // from the old TradingPair
        guard let model = model else { return }

        if let oldModel = oldModel {
            if oldModel.pair != model.pair || oldModel.fix != model.fix {
                output?.updateTradingPair(pair: model.pair, fix: model.fix)
            }
        } else {
            output?.updateTradingPair(pair: model.pair, fix: model.fix)
        }
    }

    deinit {
        tradingLimitDisposable?.dispose()
        tradingLimitDisposable = nil
        
        disposables.dispose()
    }
}

extension ExchangeCreateInteractor: ExchangeCreateInput {

    fileprivate enum TradingLimit {
        case min
        case max
    }

    fileprivate enum ExchangeCreateError {
        case aboveTradingLimit
        case belowTradingLimit
        case unknown

        init(errorCode: NabuNetworkErrorCode) {
            switch errorCode {
            case .tooBigVolume:
                self = .aboveTradingLimit
            case .tooSmallVolume:
                self = .belowTradingLimit
            case .resultCurrencyRatioTooSmall:
                self = .belowTradingLimit
            default:
                self = .unknown
            }
        }

        var message: String {
            switch self {
            case .aboveTradingLimit: return LocalizationConstants.Exchange.aboveTradingLimit
            case .belowTradingLimit: return LocalizationConstants.Exchange.belowTradingLimit
            case .unknown: return LocalizationConstants.Errors.error
            }
        }
    }
    
    func setup() {
        
        updatedInput()
        
        markets.setup()
        
        NotificationCenter.when(Constants.NotificationKeys.transactionReceived) { [weak self] _ in
            self?.refreshAccounts()
        }
        
        NotificationCenter.when(Constants.NotificationKeys.exchangeSubmitted) { [weak self] _ in
            self?.refreshAccounts()
        }
    }
    
    func resume() {
        // Authenticate, then listen for conversions
        guard let model = model else { return }
        if tradeExecution.canTradeAssetType(model.pair.from) == false {
            if let _ = errorMessage(for: model.pair.from) {
                status = .error(.waitingOnEthereumPayment)
            } else {
                status = .error(.default(nil))
            }
        }
        
        updateOutput()
        
        markets.authenticate(completion: { [unowned self] in
            self.tradeLimitService.initialize(withFiatCurrency: model.fiatCurrencyCode)
            self.subscribeToConversions()
            self.updateMarketsConversion()
            self.subscribeToBestRates()
        })
    }

    func updateMarketsConversion() {
        guard let model = model else {
            Logger.shared.error("Updating conversion with no model")
            return
        }
        markets.updateConversion(model: model)
    }

    func updatedInput() {
        // Update model volume
        guard let model = model else {
            Logger.shared.error("Updating input with no model")
            return
        }
        model.volume = inputs.activeInputValue

        // Update interface to reflect what has been typed
        updateOutput()

        // Re-subscribe to socket with new volume value
        updateMarketsConversion()
    }

    func updateOutput() {
        // Update the inputs in crypto and fiat
        guard let output = output else { return }
        guard let model = model else { return }
        let symbol = model.fiatCurrencySymbol
        let suffix = model.pair.from.symbol
        
        let secondaryAmount = conversions.output == "0" ? "0.00": conversions.output
        let secondaryResult = model.isUsingFiat ? (secondaryAmount + " " + suffix) : (symbol + secondaryAmount)

        output.updatedInput(
            primary: inputs.attributedInputValue,
            secondary: secondaryResult
        )
        
        let address = model.marketPair.fromAccount.address.address
        let type = model.marketPair.pair.from
        
        repository.accounts(for: type).asObservable()
            .subscribeOn(MainScheduler.asyncInstance)
            .flatMap { [weak self] accounts -> Observable<(Decimal, Decimal)> in
                guard let self = self else { return Observable.empty() }
                guard let account = accounts.filter({ $0.address.address == address }).first else { return Observable.empty() }
                let observable = self.markets.fiatBalance(
                    forAssetAccount: account,
                    fiatCurrencyCode:
                    model.fiatCurrencyCode
                )
                return Observable.combineLatest(observable, Observable.just(account.balance))
            }
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] fiatBalance, cryptoBalance in
                guard let self = self else { return }
                guard type == self.model?.marketPair.pair.from else { return }
                let fiatValue = FiatValue.create(amount: fiatBalance, currencyCode: model.fiatCurrencyCode)
                let cryptoValue = CryptoValue.createFromMajorValue(cryptoBalance, assetType: type.toCryptoCurrency())
                self.output?.updateBalance(
                    cryptoValue: cryptoValue,
                    fiatValue: fiatValue
                )
            })
            .disposed(by: accountDisposeBag)
    }

    func updateTradingValues(left: String, right: String) {
        output?.updateTradingPairValues(left: left, right: right)
    }

    func toggleFix() {
        guard let model = model else { return }
        model.toggleFix()
        model.lastConversion = nil
        clearInputs()
        updatedInput()
        output?.updateTradingPair(pair: model.pair, fix: model.fix)
    }
    
    func onBackspaceTapped() {
        guard inputs.canBackspace() else {
            output?.entryRejected()
            return
        }

        inputs.backspace()

        // Clear conversions if the user backspaced all the way to 0
        if !inputs.canBackspace() {
            clearInputs()
        }

        updatedInput()
    }

    func onAddInputTapped(value: String) {
        guard model != nil else {
            Logger.shared.error("Updating conversion with no model")
            return
        }
        guard inputs.canAdd(character: Character(value)) else {
            output?.entryRejected()
            return
        }
        inputs.add(character: Character(value))
        updatedInput()
    }
    
    func onDelimiterTapped() {
        guard inputs.canAddDelimiter() else {
            output?.entryRejected()
            return
        }
        inputs.addDelimiter()
        updatedInput()
    }

    func changeMarketPair(marketPair: MarketPair) {
        guard let model = model else { return }

        // Unsubscribe from old pair conversions
        Logger.shared.debug("Unsubscribing from old currency pair '\(model.pair.stringRepresentation)'")
        markets.unsubscribeToCurrencyPair(pair: model.pair.stringRepresentation)

        // Update to new pair
        model.marketPair = marketPair
        
        /// Fetching the user's balance can sometimes take as much as two seconds
        /// so if that request is still in flight, we want to dispose of it by
        /// creating a new `DisposeBag`. This ensures that we show the user's correct balance
        /// every time they change their wallet selection. Typically this
        /// is when the user has mulitple HD accounts.
        accountDisposeBag = DisposeBag()
        updatedInput()
        output?.updateTradingPair(pair: model.pair, fix: model.fix)
    }
    
    func confirmationIsExecuting() -> Bool {
        return tradeExecution.isExecuting
    }

    func confirmConversion() {
        guard let model = model else { return }
        guard let conversion = model.lastConversion else {
            Logger.shared.error("No conversion stored")
            return
        }
        guard let output = output else { return }
        output.loadingVisibility(.visible)
        self.tradeExecution.prebuildOrder(
            with: conversion,
            from: model.marketPair.fromAccount,
            to: model.marketPair.toAccount,
            success: { [weak self] orderTransaction, conversion in
                guard let this = self else { return }
                this.output?.loadingVisibility(.hidden)
                this.output?.showSummary(orderTransaction: orderTransaction, conversion: conversion)
            }, error: { [weak self] errorMessage in
                guard let this = self else { return }
                /// BTC transactions that have insufficient funds will return
                /// a very long error message that contains the below string. We want to
                /// report the true error that we're receiving from JS but we don't want to show
                /// it to the user. We show a more user friendly error message instead. 
                if errorMessage.contains("NO_UNSPENT_OUTPUTS") {
                    this.status = .error(.insufficientFundsForFees(.bitcoin))
                } else {
                    this.status = .error(.default(errorMessage))
                }
                
                this.output?.loadingVisibility(.hidden)
            }
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    func validateInput() {
        guard status != .inflight else { return }
        status = .inflight
        guard let model = model else { return }
        guard let output = output else { return }
        guard let conversion = model.lastConversion else {
            Logger.shared.error("No conversion stored")
            return
        }
        guard let volume = Decimal(string: conversion.quote.currencyRatio.base.crypto.value) else { return }
        guard let candidate = Decimal(string: conversion.baseFiatValue) else { return }
        guard tradeExecution.canTradeAssetType(model.pair.from) else {
            if let _ = errorMessage(for: model.pair.from) {
                status = .error(.waitingOnEthereumPayment)
            } else {
                // This shouldn't happen because the only case (eth) should have an error message,
                // but just in case show an error here
                status = .error(.default(nil))
            }
            return
        }
        
        let fromAssetType = model.marketPair.pair.from
        let address = model.marketPair.fromAccount.address.address
        
        /// Volume is used for XLM in this case. `tradeExecution` has
        /// references to XLM specific services so it can validate
        /// that the volume valid by using the ledger.
        /// This will return `true` for all other asset types other than `.stellar` O
        let disposable = tradeExecution.validateVolume(volume, for: model.marketPair.fromAccount)
            .asObservable()
            .subscribeOn(MainScheduler.asyncInstance)
            .flatMapLatest { [weak self] error -> Observable<([AssetAccount], Decimal, Decimal, Decimal?, Decimal?)> in
                guard let strongSelf = self else {
                    return Observable.empty()
                }
                if let error = error {
                    return Observable.error(error)
                }
                let min = strongSelf.minTradingLimit().asObservable()
                let max = strongSelf.maxTradingLimit().asObservable()
                let daily = strongSelf.dailyAvailable().asObservable()
                let annual = strongSelf.annualAvailable().asObservable()
                
                /// The reason we have a `repository` in this class is we need to
                /// validate that the user has the necessary funds to make a swap.
                /// So, we have to do a fresh fetch of the account details for the asset.
                let accounts = strongSelf.repository.accounts(for: fromAssetType).asObservable()
                return Observable.zip(accounts, min, max, daily, annual)
            }
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: { [weak self] payload in
                guard let strongSelf = self else {
                    return
                }

                let accounts = payload.0
                let minValue = payload.1
                let maxValue = payload.2
                let daily = payload.3
                let annual = payload.4
                
                guard let account = accounts.first(where: { $0.address.address == address }) else { return }

                if account.balance < volume {
                    let cryptoValue = CryptoValue.createFromMajorValue(
                        account.balance,
                        assetType: fromAssetType.toCryptoCurrency()
                    )
                    strongSelf.status = .error(.insufficientFunds(cryptoValue))
                    return
                }

                let greatestFiniteMagnitude = Decimal.greatestFiniteMagnitude

                let periodicLimit = daily ?? annual ?? 0

                switch candidate {
                case ..<minValue:
                    let fiatValue = FiatValue.create(amount: minValue, currencyCode: model.fiatCurrencyCode)
                    strongSelf.status = .error(.belowTradingLimit(fiatValue, fromAssetType))
                case periodicLimit..<greatestFiniteMagnitude:
                    let fiatValue = FiatValue.create(amount: daily ?? 0, currencyCode: model.fiatCurrencyCode)
                    strongSelf.status = .error(.aboveTierLimit(fiatValue, fromAssetType))
                case maxValue..<greatestFiniteMagnitude:
                    let fiatValue = FiatValue.create(amount: maxValue, currencyCode: model.fiatCurrencyCode)
                    strongSelf.status = .error(.aboveTradingLimit(fiatValue, fromAssetType))
                default:
                    strongSelf.status = .valid
                    output.exchangeButtonVisibility(.visible)
                    output.exchangeButtonEnabled(true)
                }
            }, onError: { [weak self] error in
                if let tradingError = error as? TradeExecutionAPIError {
                    switch tradingError {
                    case .generic:
                        self?.status = .error(.default(nil))
                    case .exceededMaxVolume(let value):
                        self?.status = .error(.aboveMaxVolume(value))
                    }
                }
            })
        disposables.insertWithDiscardableResult(disposable)
    }

    // MARK: - Private
    
    private func refreshAccounts() {
        status = .inflight
        let disposable = self.repository.fetchAccounts()
            .subscribeOn(MainScheduler.asyncInstance)
            .observeOn(MainScheduler.instance)
            .subscribe(onSuccess: { [weak self] accounts in
                guard let self = self else { return }
                self.updatedInput()
                self.validateInput()
            })
        disposables.insertWithDiscardableResult(disposable)
    }
    
    private func formatLimit(fiatCurrencySymbol: String, value: Decimal) -> String {
        let value = NumberFormatter.localCurrencyFormatter.string(for: value) ?? ""
        let limit = fiatCurrencySymbol + value
        return limit
    }

    private func subscribeToBestRates() {
        let bestRatesDisposable = markets.bestExchangeRates()
        .subscribe(onNext: { [weak self] rates in
            guard let strongSelf = self else { return }

            guard let marketsModel = strongSelf.model else { return }

            let fiatCode = marketsModel.fiatCurrencyCode

            let metadata = ExchangeRateMetadata(
                currencyCode: fiatCode,
                fromAsset: marketsModel.pair.from,
                toAsset: marketsModel.pair.to,
                rates: rates.rates
            )
            strongSelf.output?.updateRateMetadata(metadata)
        })
        disposables.insertWithDiscardableResult(bestRatesDisposable)
    }

    private func subscribeToConversions() {
        let conversionsDisposable = markets.conversions.subscribe(onNext: { [weak self] conversion in
            guard let this = self else { return }

            guard let model = this.model else { return }

            guard model.pair.stringRepresentation == conversion.quote.pair else {
                Logger.shared.warning(
                    "Pair '\(conversion.quote.pair)' is different from model pair '\(model.pair.stringRepresentation)'."
                )
                return
            }
            
            guard model.lastConversion != conversion else { return }

            // Store conversion
            model.lastConversion = conversion

            // Use conversions service to determine new input/output
            this.conversions.update(with: conversion)

            // Update interface to reflect the values returned from the conversion
            // Update input labels
            this.updateOutput()

            // Update trading pair view values
            this.updateTradingValues(left: this.conversions.baseOutput, right: this.conversions.counterOutput)

            this.validateInput()
        }, onError: { error in
            Logger.shared.error("Error subscribing to quote with trading pair")
        })

        let errorDisposable = markets.errors.subscribe(onNext: { [weak self] socketError in
            guard let this = self else { return }
            guard let model = this.model else { return }
            guard let output = this.output else { return }

            guard this.tradeExecution.canTradeAssetType(model.pair.from) else {
                if let _ = this.errorMessage(for: model.pair.from) {
                    this.status = .error(.waitingOnEthereumPayment)
                } else {
                    // This shouldn't happen because the only case (eth) should have an error message,
                    // but just in case show an error here
                    this.status = .error(.default(nil))
                }
                return
            }

            let symbol = model.fiatCurrencySymbol
            let suffix = model.pair.from.symbol
            
            let secondaryAmount = "0.00"
            let secondaryResult = model.isUsingFiat ? (secondaryAmount + " " + suffix) : (symbol + secondaryAmount)
            
            /// When users are above or below the trading limit, `conversion.output` will not be updated
            /// with the correct conversion value. This is because the volume entered is either too little
            /// or too large. In this case we want the `secondaryAmountLabel` to read as `0.00`. We don't
            /// want to update `conversion.output` manually though as that'd be a side-effect.
            output.updatedInput(
                primary: this.inputs.attributedInputValue,
                secondary: secondaryResult
            )

            let min = this.minTradingLimit().asObservable()
            let max = this.maxTradingLimit().asObservable()
            let disposable = Observable.zip(min, max)
                .subscribeOn(MainScheduler.asyncInstance)
                .observeOn(MainScheduler.instance)
                .subscribe(onNext: { (minimum, maximum) in
                    let minFiat = FiatValue.create(amount: minimum, currencyCode: model.fiatCurrencyCode)
                    let maxFiat = FiatValue.create(amount: maximum, currencyCode: model.fiatCurrencyCode)
                    switch socketError.errorType {
                    case .currencyRatioError:
                        switch socketError.code {
                        case .tooBigVolume:
                            this.status = .error(.aboveTradingLimit(maxFiat, model.marketPair.pair.from))
                        case .tooSmallVolume,
                             .resultCurrencyRatioTooSmall:
                            this.status = .error(.belowTradingLimit(minFiat, model.marketPair.pair.from))
                        default:
                            this.status = .error(.default(nil))
                        }
                    case .default:
                        this.status = .error(.default(nil))
                    }
                })
            this.disposables.insertWithDiscardableResult(disposable)
        })

        disposables.insertWithDiscardableResult(conversionsDisposable)
        disposables.insertWithDiscardableResult(errorDisposable)
    }

    private func applyValue(stringValue: String) {
        stringValue.unicodeScalars.forEach { char in
            let charStringValue = String(char)
            if CharacterSet.decimalDigits.contains(char) {
                onAddInputTapped(value: charStringValue)
            } else if "." == charStringValue {
                onDelimiterTapped()
            }
        }
    }
    
    private func minTradingLimit() -> Maybe<Decimal> {
        return tradingLimitInfo(info: { tradingLimits -> Decimal in
            return tradingLimits.minOrder
        })
    }
    
    private func maxTradingLimit() -> Maybe<Decimal> {
        return tradingLimitInfo(info: { tradingLimits -> Decimal in
            return tradingLimits.maxPossibleOrder
        })
    }

    private func dailyAvailable() -> Maybe<Decimal?> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(
            withFiatCurrency: model.fiatCurrencyCode,
            ignoringCache: false).asMaybe().map { limits -> Decimal? in
            return limits.daily?.available
        }
    }

    private func annualAvailable() -> Maybe<Decimal?> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(
            withFiatCurrency: model.fiatCurrencyCode,
            ignoringCache: false).asMaybe().map { limits -> Decimal? in
            return limits.annual?.available
        }
    }

    // Need to ensure that these are newly fetched after each trade
    private func tradingLimitInfo(info: @escaping (TradeLimits) -> Decimal) -> Maybe<Decimal> {
        guard let model = model else {
            return Maybe.empty()
        }
        return tradeLimitService.getTradeLimits(
            withFiatCurrency: model.fiatCurrencyCode,
            ignoringCache: false).map { tradingLimits -> Decimal in
            return info(tradingLimits)
        }.asMaybe()
    }

    private func clearInputs() {
        inputs.clear()
        conversions.clear()
        output?.updateTradingPairValues(left: "", right: "")
    }

    // Error message to show if the user is not allowed to trade a certain asset type
    private func errorMessage(for assetType: AssetType) -> String? {
        switch assetType {
        case .ethereum: return LocalizationConstants.SendEther.waitingForPaymentToFinishMessage
        default: return nil
        }
    }
}

extension ExchangeRates {
    func exchangeRateDescription(fromCurrency: String, toCurrency: String) -> String {
        guard let rate = pairRate(fromCurrency: fromCurrency, toCurrency: toCurrency) else {
            return ""
        }
        return "1 \(fromCurrency) = \(rate.price) \(toCurrency)"
    }
}

fileprivate extension AssetType {
    /// NOTE: This is used for `ExchangeInputViewModel`.
    /// The view model can provide a `FiatValue` or `CryptoValue`. When
    /// returning a `CryptoValue` we must provide the `CrptoValue` 
    func toCryptoCurrency() -> CryptoCurrency {
        switch self {
        case .bitcoin:
            return .bitcoin
        case .bitcoinCash:
            return .bitcoinCash
        case .stellar:
            return .stellar
        case .ethereum:
            return .ethereum
        }
    }
}
