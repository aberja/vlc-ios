/*****************************************************************************
 * MediaScrubProgressBar.swift
 *
 * Copyright © 2019-2020 VLC authors and VideoLAN
 *
 * Authors: Robert Gordon <robwaynegordon@gmail.com>
 *          Soomin Lee <bubu@mikan.io>
 *          Diogo Simao Marques <dogo@videolabs.io>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

@objc(VLCMediaScrubProgressBarDelegate)
protocol MediaScrubProgressBarDelegate: AnyObject {
    @objc optional func mediaScrubProgressBarShouldResetIdleTimer()
    func mediaScrubProgressBarSetPlaybackPosition(to value: Float)
    func mediaScrubProgressBarGetAMark() -> ABRepeatMarkView
    func mediaScrubProgressBarGetBMark() -> ABRepeatMarkView
}

@objc(VLCMediaScrubProgressBar)
class MediaScrubProgressBar: UIStackView {
    weak var delegate: MediaScrubProgressBarDelegate?
    private var playbackService = PlaybackService.sharedInstance()
    private var positionSet: Bool = true
    private(set) var isScrubbing: Bool = false
    var shouldHideScrubLabels: Bool = false

    @objc lazy private(set) var progressSlider: VLCOBSlider = {
        var slider = VLCOBSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = PresentationTheme.current.colors.orangeUI
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.2)
        slider.setThumbImage(UIImage(named: "sliderThumb"), for: .normal)
        slider.setThumbImage(UIImage(named: "sliderThumbBig"), for: .highlighted)
        slider.isContinuous = true
        slider.semanticContentAttribute = .forceLeftToRight
        slider.accessibilityIdentifier = VLCAccessibilityIdentifier.videoPlayerScrubBar
        slider.addTarget(self, action: #selector(handleSlide(slider:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(progressSliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(progressSliderTouchUp), for: .touchUpInside)
        slider.addTarget(self, action: #selector(progressSliderTouchUp), for: .touchUpOutside)
        slider.addTarget(self, action: #selector(updateScrubLabel), for: .touchDragInside)
        slider.addTarget(self, action: #selector(updateScrubLabel), for: .touchDragOutside)
        return slider
    }()
    
    private lazy var elapsedTimeLabel: UILabel = {
        var label = UILabel()
        label.font = UIFont.preferredCustomFont(forTextStyle: .subheadline).bolded
        label.textColor = PresentationTheme.current.colors.orangeUI
        label.text = "--:--"
        label.numberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.semanticContentAttribute = .forceLeftToRight
        return label
    }()
    
    private(set) lazy var remainingTimeButton: UIButton = {
        let remainingTimeButton = UIButton(type: .custom)
        remainingTimeButton.addTarget(self,
                                      action: #selector(handleTimeDisplay),
                                      for: .touchUpInside)
        remainingTimeButton.setTitle("--:--", for: .normal)
        remainingTimeButton.setTitleColor(.white, for: .normal)

        // Use a monospace variant for the digits so the width does not jitter as the numbers changes.
        remainingTimeButton.titleLabel?.font = UIFont.preferredCustomFont(forTextStyle: .subheadline).semibolded

        remainingTimeButton.semanticContentAttribute = .forceLeftToRight
        remainingTimeButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return remainingTimeButton
    }()

    private lazy var scrubbingIndicatorLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .white
        label.textAlignment = .center
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        label.backgroundColor = UIColor(white: 0, alpha: 0.4)
        return label
    }()

    private lazy var scrubbingHelpLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 10)
        label.textColor = .white
        label.text = NSLocalizedString("PLAYBACK_SCRUB_HELP", comment: "")
        label.setContentHuggingPriority(.defaultHigh, for: .vertical)
        label.backgroundColor = UIColor(white: 0, alpha: 0.4)
        label.textAlignment = .center
        return label
    }()

    private lazy var scrubInfoStackView: UIStackView = {
        let scrubInfoStackView = UIStackView(arrangedSubviews: [scrubbingIndicatorLabel, scrubbingHelpLabel])
        scrubInfoStackView.axis = .vertical
        scrubInfoStackView.isHidden = true
        return scrubInfoStackView
    }()
    
    // MARK: Initializers
    required init(coder: NSCoder) {
        fatalError("init(coder: NSCoder) not implemented")
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        initAccessibility()

        NotificationCenter.default.addObserver(self, selector: #selector(handleWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    private func initAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("PLAYBACK_POSITION", comment: "")
        accessibilityTraits = .updatesFrequently

        let forward = UIAccessibilityCustomAction
            .create(name: NSLocalizedString("FWD_BUTTON", comment: ""),
                    image: .with(systemName: "plus.arrow.trianglehead.clockwise"),
                    target: self,
                    selector: #selector(handleAccessibilityForward))

        let backward = UIAccessibilityCustomAction
            .create(name: NSLocalizedString("BWD_BUTTON", comment: ""),
                    image: .with(systemName: "minus.arrow.trianglehead.counterclockwise"),
                    target: self,
                    selector: #selector(handleAccessibilityBackward))

        let timeDisplay = UIAccessibilityCustomAction
            .create(name: NSLocalizedString("PLAYBACK_SCRUB_ACCESSIBILITY_TIME_DISPLAY", comment: ""),
                    image: nil,
                    target: self,
                    selector: #selector(handleAccessibilityTimeDisplay))

        accessibilityCustomActions = [forward, backward, timeDisplay]

        updateAccessibilityValue()
    }

    @objc private func handleAccessibilityForward() -> Bool {
        let defaults = UserDefaults.standard
        playbackService.jumpForward(Int32(defaults.integer(forKey: kVLCSettingPlaybackForwardSkipLength)))
        return true
    }

    @objc private func handleAccessibilityBackward() -> Bool {
        let defaults = UserDefaults.standard
        playbackService.jumpBackward(Int32(defaults.integer(forKey: kVLCSettingPlaybackBackwardSkipLength)))
        return true
    }

    @objc private func handleAccessibilityTimeDisplay() -> Bool {
        handleTimeDisplay()
        return true
    }

    @objc func updateInterfacePosition() {
        if !isScrubbing {
            progressSlider.value = playbackService.playbackPosition
        }

        updateProgressValueIfNeeded()

        elapsedTimeLabel.text = playbackService.playedTime().stringValue

        updateCurrentTime()

        elapsedTimeLabel.setNeedsLayout()

        updateAccessibilityValue()
    }

    func updateCurrentTime() {
        let timeToDisplay: String = {
            switch RemainingTimeMode.current {
            case .remaining:
                return playbackService.remainingTime().stringValue
            case .total:
                return playbackService.mediaLength.stringValue
            }
        }()

        remainingTimeButton.setTitle(timeToDisplay, for: .normal)
        remainingTimeButton.setNeedsLayout()
    }

    func updateProgressValues() {
        elapsedTimeLabel.text = playbackService.playedTime().stringValue
        progressSlider.value = playbackService.playbackPosition

        updateCurrentTime()
    }

    func updateSliderWithValue(value: Float) {
        perform(#selector(updatePlaybackPosition), with: nil, afterDelay: 0.3)
        progressSlider.value = value / Float(playbackService.mediaDuration)
        playbackService.playbackPosition = value / Float(playbackService.mediaDuration)

        let newPosition = VLCTime(number: NSNumber.init(value: value))
        elapsedTimeLabel.text = newPosition.stringValue
        elapsedTimeLabel.accessibilityLabel =
            String(format: "%@: %@",
                   NSLocalizedString("PLAYBACK_POSITION", comment: ""),
                   newPosition.stringValue)
        if RemainingTimeMode.current == .remaining {
            let newRemainingTime = Int(newPosition.intValue) - playbackService.mediaDuration
            remainingTimeButton.setTitle(VLCTime(number: NSNumber.init(value: newRemainingTime)).stringValue, for: .normal)
            remainingTimeButton.setNeedsLayout()
        }
        elapsedTimeLabel.setNeedsLayout()

        positionSet = false
        delegate?.mediaScrubProgressBarShouldResetIdleTimer?()
    }

    func updateBackgroundAlpha(with alpha: CGFloat) {
        scrubbingIndicatorLabel.backgroundColor = UIColor(white: 0, alpha: alpha)
        scrubbingHelpLabel.backgroundColor = UIColor(white: 0, alpha: alpha)
    }

    func setMark(_ mark: ABRepeatMarkView) {
        // Round the value at 4 decimals in order to be able to properly compare
        // it with the playbackService's playback position value.
        let roundValue = round(progressSlider.value * 10000) / 10000.0
        mark.setPosition(at: roundValue)
        let position = CGFloat(roundValue) * progressSlider.frame.width
        setupMarkConstraints(for: mark, at: position)
    }

    func setupMarkConstraints(for mark: ABRepeatMarkView, at position: CGFloat) {
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor, constant: position),
            mark.bottomAnchor.constraint(equalTo: progressSlider.topAnchor),
            mark.widthAnchor.constraint(equalToConstant: 15),
            mark.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    func adjustABRepeatMarks(aMark: ABRepeatMarkView, bMark: ABRepeatMarkView) {
        guard aMark.isEnabled else {
            return
        }

        aMark.removeFromSuperview()
        let aMarkPosition = CGFloat(aMark.getPosition()) * progressSlider.frame.width
        setupMarkConstraints(for: aMark, at: aMarkPosition)

        guard bMark.isEnabled else {
            return
        }

        bMark.removeFromSuperview()
        let bMarkPosition = CGFloat(bMark.getPosition()) * progressSlider.frame.width
        setupMarkConstraints(for: bMark, at: bMarkPosition)
    }
}

// MARK: -

private extension MediaScrubProgressBar {
    private func setupViews() {
        let horizontalStack = UIStackView(arrangedSubviews: [elapsedTimeLabel, remainingTimeButton])
        horizontalStack.distribution = .equalSpacing
        horizontalStack.semanticContentAttribute = .forceLeftToRight
        addArrangedSubview(scrubInfoStackView)
        addArrangedSubview(horizontalStack)
        addArrangedSubview(progressSlider)
        spacing = 5
        axis = .vertical
        translatesAutoresizingMaskIntoConstraints = false

        setVerticalHuggingAndCompressionResistance(to: .required, for: [
            scrubbingHelpLabel,
            scrubbingIndicatorLabel,
            elapsedTimeLabel,
            remainingTimeButton,
            scrubInfoStackView,
            horizontalStack,
            progressSlider
        ])

        elapsedTimeLabel.setContentHuggingPriority(.required, for: .vertical)
        remainingTimeButton.setContentHuggingPriority(.required, for: .vertical)
        scrubInfoStackView.setContentHuggingPriority(.required, for: .vertical)
        horizontalStack.setContentHuggingPriority(.required, for: .vertical)
        progressSlider.setContentHuggingPriority(.required, for: .vertical)
    }

    private func setVerticalHuggingAndCompressionResistance(to priority: UILayoutPriority, for views: [UIView]) {
        for view in views {
            view.setContentHuggingPriority(priority, for: .vertical)
            view.setContentCompressionResistancePriority(priority, for: .vertical)
        }
    }

    @objc private func updateScrubLabel() {
        guard !shouldHideScrubLabels else {
            return
        }

        let speed = progressSlider.scrubbingSpeed
        if  speed == 1 {
            scrubbingIndicatorLabel.text = NSLocalizedString("PLAYBACK_SCRUB_HIGH", comment:"")
        } else if speed == 0.5 {
            scrubbingIndicatorLabel.text = NSLocalizedString("PLAYBACK_SCRUB_HALF", comment: "")
        } else if speed == 0.25 {
            scrubbingIndicatorLabel.text = NSLocalizedString("PLAYBACK_SCRUB_QUARTER", comment: "")
        } else {
            scrubbingIndicatorLabel.text = NSLocalizedString("PLAYBACK_SCRUB_FINE", comment: "")
        }
    }

    @objc private func updatePlaybackPosition() {
        if !positionSet {
            playbackService.playbackPosition = progressSlider.value
            playbackService.setNeedsMetadataUpdate()
            positionSet = true
        }
    }

    private func updateProgressValueIfNeeded() {
        let roundProgress = round(progressSlider.value * 10000) / 10000.0

        guard let aMark = delegate?.mediaScrubProgressBarGetAMark(),
              let bMark = delegate?.mediaScrubProgressBarGetBMark(),
              aMark.isEnabled && bMark.isEnabled else {
            return
        }

        let minPosition = aMark.getPosition() < bMark.getPosition() ? aMark.getPosition() : bMark.getPosition()
        let maxPosition = aMark.getPosition() > bMark.getPosition() ? aMark.getPosition() : bMark.getPosition()

        guard roundProgress < minPosition || roundProgress > maxPosition else {
            return
        }

        delegate?.mediaScrubProgressBarSetPlaybackPosition(to: minPosition)
        progressSlider.value = minPosition
    }

    private func updateAccessibilityValue() {
        switch RemainingTimeMode.current {
        case .total:
            accessibilityValue = String(format: NSLocalizedString("PLAYBACK_SCRUB_TOTAL_TIME_FORMAT", comment: "1: elapsed time, 2: total time"),
                                        playbackService.playedTime().verboseStringValue,
                                        playbackService.mediaLength.verboseStringValue)

        case .remaining:
            accessibilityValue = String(format: NSLocalizedString("PLAYBACK_SCRUB_REMAINING_TIME_FORMAT", comment: "1: elapsed time, 2: remaining time"),
                                        playbackService.playedTime().verboseStringValue,
                                        playbackService.remainingTime().verboseStringValue)

        }
    }

    // MARK: -

    @objc private func handleTimeDisplay() {
        RemainingTimeMode.toggle()

        updateCurrentTime()
        delegate?.mediaScrubProgressBarShouldResetIdleTimer?()
    }

    // MARK: - Slider Methods

    @objc private func handleSlide(slider: UISlider) {
        /* we need to limit the number of events sent by the slider, since otherwise, the user
         * wouldn't see the I-frames when seeking on current mobile devices. This isn't a problem
         * within the Simulator, but especially on older ARMv7 devices, it's clearly noticeable. */
        perform(#selector(updatePlaybackPosition), with: nil, afterDelay: 0.3)
        if playbackService.mediaDuration > 0 {
            if !isScrubbing {
                progressSlider.value = playbackService.playbackPosition
            }

            let newPosition = VLCTime(number: NSNumber.init(value: slider.value * Float(playbackService.mediaDuration)))
            elapsedTimeLabel.text = newPosition.stringValue
            elapsedTimeLabel.accessibilityLabel =
                String(format: "%@: %@",
                       NSLocalizedString("PLAYBACK_POSITION", comment: ""),
                       newPosition.stringValue)
            // Update only remaining time and not media duration.
            if RemainingTimeMode.current == .remaining {
                let newRemainingTime = Int(newPosition.intValue) - playbackService.mediaDuration
                remainingTimeButton.setTitle(VLCTime(number: NSNumber.init(value:newRemainingTime)).stringValue,
                                             for: .normal)
                remainingTimeButton.setNeedsLayout()
            }

            elapsedTimeLabel.setNeedsLayout()
        }
        positionSet = false
        delegate?.mediaScrubProgressBarShouldResetIdleTimer?()
    }

    @objc private func progressSliderTouchDown() {
        updateScrubLabel()
        isScrubbing = true
        scrubInfoStackView.isHidden = shouldHideScrubLabels ? true : !isScrubbing
    }

    @objc private func progressSliderTouchUp() {
        isScrubbing = false
        scrubInfoStackView.isHidden = shouldHideScrubLabels ? true : !isScrubbing
    }

    @objc private func handleWillResignActive() {
        progressSliderTouchUp()
    }
}

// MARK: -

fileprivate enum RemainingTimeMode {
    case total
    case remaining

    static var current: RemainingTimeMode {
        let userDefault = UserDefaults.standard
        let currentSetting = userDefault.bool(forKey: kVLCShowRemainingTime)

        switch currentSetting {
            case true: return .remaining
            case false: return .total
        }
    }

    @discardableResult
    static func toggle() -> RemainingTimeMode {
        let userDefault = UserDefaults.standard
        userDefault.set(!userDefault.bool(forKey: kVLCShowRemainingTime), forKey: kVLCShowRemainingTime)
        return current
    }
}
