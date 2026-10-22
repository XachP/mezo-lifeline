// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves} from "./interfaces/IMezo.sol";

/// @title LifelineVault (Lifeline: auto-rescue for MUSD troves)
/// @notice A smart account that owns ONE mUSD trove on Mezo and protects it from liquidation.
///         The owner parks a BTC and/or MUSD "rescue reserve" inside the vault and sets a policy
///         (trigger ICR, target ICR, keeper tip). When the trove's collateral ratio falls below the
///         trigger (or below the Recovery-Mode danger line), ANYONE may call `protect()`: the vault
///         tops up collateral from the BTC reserve and/or repays debt from the MUSD reserve until the
///         trove is back at the target ratio, and pays the caller a small capped tip.
///         Optional redemption guard: also rescue when too little other MUSD debt sits ahead of this
///         trove in the redemption queue, by raising its ICR just past that point.
///         Keepers can never withdraw, borrow, or move funds anywhere except into the owner's trove.
contract LifelineVault {
    // ---- protocol constants (mirroring mUSD's LiquityBase) ----
    uint256 public constant MCR = 1.1e18; // 110%: below this a trove is liquidatable
    uint256 public constant CCR = 1.5e18; // 150%: system Recovery Mode threshold
    uint256 public constant RECOVERY_BUFFER = 0.05e18; // stay 5 points above CCR in Recovery Mode
    uint256 public constant GAS_COMPENSATION = 200e18; // MUSD reserved for liquidators
    uint256 public constant MAX_TIP_BPS = 200; // keeper tip can never exceed 2% of the rescue size
    uint256 public constant MAX_REDEMPTION_ICR = 2.5e18; // redemption guard never chases the queue above 250%
    uint256 public constant REDEMPTION_MARGIN = 0.02e18; // sit 2 points above the last trove in the buffer
    uint256 public constant REDEMPTION_HYSTERESIS = 0.01e18; // rescue overshoots the safe ICR by 1 point
    uint256 public constant MAX_QUEUE_STEPS = 60; // bound on the SortedTroves walk

    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IERC20Min public immutable musd;
    ISortedTroves public immutable sortedTroves;
    address public immutable owner;
    address public immutable factory;

    struct Policy {
        uint64 triggerICR; // e.g. 1.30e18: protect when ICR drops below this
        uint64 targetICR; // e.g. 1.60e18: restore ICR to this
        uint16 tipBps; // keeper tip, in bps of rescue size (BTC value)
        uint128 maxTipWei; // absolute cap on the keeper tip, in BTC wei
        uint128 redemptionBufferMusd; // 0 = off. Else: keep at least this much other MUSD debt ahead of
            // this trove in mUSD's redemption queue (redemptions hit the lowest-ICR troves >= 110% first)
    }

    Policy public policy;
    uint256 private _locked = 1;

    event PolicyUpdated(
        uint256 triggerICR, uint256 targetICR, uint256 tipBps, uint256 maxTipWei, uint256 redemptionBufferMusd
    );
    event TroveOpened(uint256 collateral, uint256 debt);
    event ReserveFunded(address indexed from, uint256 btc, uint256 musdAmount);
    event ReserveWithdrawn(uint256 btc, uint256 musdAmount);
    event Protected(
        address indexed keeper,
        uint256 icrBefore,
        uint256 icrAfter,
        uint256 collAdded,
        uint256 musdRepaid,
        uint256 tip,
        bool recoveryMode,
        bool redemptionGuard
    );

    error NotOwner();
    error Reentrancy();
    error BadPolicy();
    error Healthy(uint256 icr, uint256 trigger);
    error NoActiveTrove();
    error ReserveTooSmall(uint256 icrReachable);
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address _owner,
        IBorrowerOperations _bo,
        ITroveManager _tm,
        IPriceFeed _pf,
        IERC20Min _musd,
        ISortedTroves _sortedTroves,
        Policy memory _policy
    ) {
        owner = _owner;
        factory = msg.sender;
        borrowerOperations = _bo;
        troveManager = _tm;
        priceFeed = _pf;
        musd = _musd;
        sortedTroves = _sortedTroves;
        _setPolicy(_policy);
    }

    /// @dev Receives BTC from the owner (reserve top-up) and from the protocol (withdrawals, surplus).
    receive() external payable {}

    // ------------------------------------------------------------------
    // Owner: trove management (vault is the borrower of record)
    // ------------------------------------------------------------------

    /// @notice Open the trove. `collateral` of msg.value goes into the trove; any extra stays as BTC reserve.
    function openTrove(uint256 collateral, uint256 debtAmount, address upperHint, address lowerHint)
        external
        payable
        onlyOwner
        nonReentrant
    {
        require(collateral <= msg.value, "collateral > value");
        borrowerOperations.openTrove{value: collateral}(debtAmount, upperHint, lowerHint);
        _sendMUSD(owner, debtAmount); // borrowed MUSD goes to the owner
        emit TroveOpened(collateral, debtAmount);
        if (msg.value > collateral) emit ReserveFunded(msg.sender, msg.value - collateral, 0);
    }

    function addColl(address upperHint, address lowerHint) external payable onlyOwner nonReentrant {
        borrowerOperations.addColl{value: msg.value}(upperHint, lowerHint);
    }

    function withdrawColl(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        borrowerOperations.withdrawColl(amount, upperHint, lowerHint);
        _sendBTC(owner, amount);
    }

    function borrow(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        borrowerOperations.withdrawMUSD(amount, upperHint, lowerHint);
        _sendMUSD(owner, amount);
    }

    /// @notice Repay debt with MUSD pulled from the owner's wallet (owner must approve the vault first).
    function repay(uint256 amount, address upperHint, address lowerHint) external onlyOwner nonReentrant {
        if (!musd.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        borrowerOperations.repayMUSD(amount, upperHint, lowerHint);
    }

    /// @notice Close the trove. MUSD needed beyond the vault's reserve is pulled from the owner (approve first).
    ///         All BTC (released collateral + reserve) and leftover MUSD go back to the owner.
    function closeTrove() external onlyOwner nonReentrant {
        (uint256 debt,) = _debtAndColl();
        uint256 needed = debt - GAS_COMPENSATION;
        uint256 have = musd.balanceOf(address(this));
        if (have < needed) {
            if (!musd.transferFrom(msg.sender, address(this), needed - have)) revert TransferFailed();
        }
        borrowerOperations.closeTrove();
        _sweep();
    }

    /// @notice Claim surplus collateral after a liquidation/redemption in Recovery Mode, and sweep everything.
    function claimAndSweep() external onlyOwner nonReentrant {
        try borrowerOperations.claimCollateral() {} catch {}
        _sweep();
    }

    // ------------------------------------------------------------------
    // Owner: rescue reserve + policy
    // ------------------------------------------------------------------

    /// @notice Add BTC (msg.value) and/or MUSD (pulled, needs approval) to the rescue reserve.
    function fundReserve(uint256 musdAmount) external payable nonReentrant {
        if (musdAmount > 0 && !musd.transferFrom(msg.sender, address(this), musdAmount)) revert TransferFailed();
        emit ReserveFunded(msg.sender, msg.value, musdAmount);
    }

    function withdrawReserve(uint256 btc, uint256 musdAmount) external onlyOwner nonReentrant {
        if (btc > 0) _sendBTC(owner, btc);
        if (musdAmount > 0) _sendMUSD(owner, musdAmount);
        emit ReserveWithdrawn(btc, musdAmount);
    }

    function setPolicy(Policy calldata p) external onlyOwner {
        _setPolicy(p);
    }

    // ------------------------------------------------------------------
    // Permissionless: protection
    // ------------------------------------------------------------------

    /// @notice Rescue the trove if it is below its (Recovery-Mode-aware) trigger. Callable by anyone.
    /// @return collAdded BTC moved from reserve into the trove
    /// @return musdRepaid MUSD from reserve used to repay debt
    /// @return tip BTC paid to msg.sender
    function protect(address upperHint, address lowerHint)
        external
        nonReentrant
        returns (uint256 collAdded, uint256 musdRepaid, uint256 tip)
    {
        if (troveManager.getTroveStatus(address(this)) != 1) revert NoActiveTrove();
        uint256 price = priceFeed.fetchPrice();
        bool rm = troveManager.checkRecoveryMode(price);
        (uint256 trigger, uint256 target) = effectiveThresholds(rm);
        uint256 icrBefore = troveManager.getCurrentICR(address(this), price);
        bool redemption;
        if (icrBefore >= trigger) {
            // Not near liquidation. Still act if we're at the front of the redemption queue.
            uint256 safe = redemptionSafeICR(price);
            if (safe == 0 || icrBefore >= safe) revert Healthy(icrBefore, trigger);
            redemption = true;
            // overshoot by one point so rounding never leaves us a hair under `safe` (no re-trigger loops)
            if (target < safe + REDEMPTION_HYSTERESIS) target = safe + REDEMPTION_HYSTERESIS;
        }

        (uint256 debt, uint256 coll) = _debtAndColl();
        Policy memory p = policy;

        // 1) Plan: how much BTC to add, and (if BTC runs short) how much MUSD to repay.
        uint256 btcReserve = address(this).balance;
        uint256 collNeeded = _ceilDiv(target * debt, price);
        collNeeded = collNeeded > coll ? collNeeded - coll : 0;
        // Reserve the worst-case tip so the rescue itself is never starved by it.
        uint256 tipCap = p.maxTipWei;
        uint256 usableBtc = btcReserve > tipCap ? btcReserve - tipCap : 0;
        collAdded = collNeeded < usableBtc ? collNeeded : usableBtc;

        uint256 newColl = coll + collAdded;
        uint256 newDebt = debt;
        if (collAdded < collNeeded) {
            // debt the trove can carry at the target ratio with the new collateral
            uint256 maxDebt = (newColl * price) / target;
            uint256 want = debt > maxDebt ? debt - maxDebt : 0;
            // mUSD rules: net debt (debt - gas comp) must stay >= minNetDebt
            uint256 floor = borrowerOperations.minNetDebt() + GAS_COMPENSATION;
            uint256 room = debt > floor ? debt - floor : 0;
            uint256 bal = musd.balanceOf(address(this));
            musdRepaid = _min(want, _min(room, bal));
            newDebt = debt - musdRepaid;
        }

        // The rescue must at least lift the trove out of liquidation range (and out of RM danger).
        uint256 reachable = newDebt == 0 ? type(uint256).max : (newColl * price) / newDebt;
        uint256 floorICR = rm ? CCR : MCR;
        if (reachable <= floorICR) revert ReserveTooSmall(reachable);

        // 2) Execute.
        if (collAdded > 0) borrowerOperations.addColl{value: collAdded}(upperHint, lowerHint);
        if (musdRepaid > 0) borrowerOperations.repayMUSD(musdRepaid, upperHint, lowerHint);

        // 3) Tip the keeper: tipBps of the rescue's BTC value, capped, paid from what is left.
        uint256 rescueValueBtc = collAdded + (musdRepaid * 1e18) / price;
        tip = _min((rescueValueBtc * p.tipBps) / 10_000, tipCap);
        tip = _min(tip, address(this).balance);
        if (tip > 0) _sendBTC(msg.sender, tip);

        uint256 icrAfter = troveManager.getCurrentICR(address(this), price);
        emit Protected(msg.sender, icrBefore, icrAfter, collAdded, musdRepaid, tip, rm, redemption);
    }

    // ------------------------------------------------------------------
    // Views (used by the keeper bot and the dashboard)
    // ------------------------------------------------------------------

    /// @notice Trigger/target after Recovery-Mode adjustment. In RM, troves under 150% can be liquidated,
    ///         so the vault treats CCR+5 points as the floor for the trigger.
    function effectiveThresholds(bool recoveryMode) public view returns (uint256 trigger, uint256 target) {
        trigger = policy.triggerICR;
        target = policy.targetICR;
        if (recoveryMode) {
            uint256 rmTrigger = CCR + RECOVERY_BUFFER;
            if (trigger < rmTrigger) trigger = rmTrigger;
            if (target < trigger + 0.1e18) target = trigger + 0.1e18;
        }
    }

    /// @notice ICR this trove needs so that at least `redemptionBufferMusd` of OTHER redeemable debt
    ///         (troves >= 110%) sits ahead of it in mUSD's redemption order. 0 = guard off / not computable
    ///         (buffer disabled, not enough debt in the system, walk too long, or above MAX_REDEMPTION_ICR).
    function redemptionSafeICR(uint256 price) public view returns (uint256) {
        uint256 buffer = policy.redemptionBufferMusd;
        if (buffer == 0) return 0;
        address cur = sortedTroves.getLast(); // lowest nominal ICR
        uint256 acc;
        for (uint256 i; i < MAX_QUEUE_STEPS && cur != address(0); i++) {
            if (cur != address(this)) {
                uint256 icr = troveManager.getCurrentICR(cur, price);
                if (icr >= MCR) {
                    (, uint256 pr, uint256 it,, uint256 pp, uint256 pi) = troveManager.getEntireDebtAndColl(cur);
                    acc += pr + it + pp + pi;
                    if (acc >= buffer) {
                        uint256 safe = icr + REDEMPTION_MARGIN;
                        return safe > MAX_REDEMPTION_ICR ? 0 : safe;
                    }
                }
            }
            cur = sortedTroves.getPrev(cur);
        }
        return 0;
    }

    struct Health {
        uint8 status;
        uint256 price;
        uint256 icr;
        uint256 trigger;
        uint256 target;
        bool recoveryMode;
        bool needsProtection;
        uint256 coll;
        uint256 debt;
        uint256 reserveBtc;
        uint256 reserveMusd;
        uint256 liquidationPrice; // BTC price at which ICR == MCR (or CCR in Recovery Mode)
        uint256 redemptionSafeICR; // 0 if the redemption guard is off
        bool redemptionRisk; // ICR below redemptionSafeICR
    }

    function health() external view returns (Health memory h) {
        h.status = troveManager.getTroveStatus(address(this));
        h.price = priceFeed.fetchPrice();
        h.recoveryMode = troveManager.checkRecoveryMode(h.price);
        (h.trigger, h.target) = effectiveThresholds(h.recoveryMode);
        h.reserveBtc = address(this).balance;
        h.reserveMusd = musd.balanceOf(address(this));
        if (h.status == 1) {
            (h.debt, h.coll) = _debtAndColl();
            h.icr = troveManager.getCurrentICR(address(this), h.price);
            h.redemptionSafeICR = redemptionSafeICR(h.price);
            h.redemptionRisk = h.redemptionSafeICR != 0 && h.icr < h.redemptionSafeICR;
            h.needsProtection = h.icr < h.trigger || h.redemptionRisk;
            uint256 line = h.recoveryMode ? CCR : MCR;
            h.liquidationPrice = h.coll == 0 ? 0 : (line * h.debt) / h.coll;
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _setPolicy(Policy memory p) internal {
        if (p.triggerICR <= MCR || p.targetICR <= p.triggerICR || p.tipBps > MAX_TIP_BPS) revert BadPolicy();
        policy = p;
        emit PolicyUpdated(p.triggerICR, p.targetICR, p.tipBps, p.maxTipWei, p.redemptionBufferMusd);
    }

    function _debtAndColl() internal view returns (uint256 debt, uint256 coll) {
        (uint256 c, uint256 pr, uint256 i, uint256 pc, uint256 pp, uint256 pi) =
            troveManager.getEntireDebtAndColl(address(this));
        coll = c; // getEntireDebtAndColl already folds pending collateral into `coll`
        debt = pr + i; // ...and pending principal/interest into principal/interest
        (pc, pp, pi); // silence unused warnings
    }

    function _sweep() internal {
        uint256 m = musd.balanceOf(address(this));
        if (m > 0) _sendMUSD(owner, m);
        uint256 b = address(this).balance;
        if (b > 0) _sendBTC(owner, b);
    }

    function _sendBTC(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _sendMUSD(address to, uint256 amount) internal {
        if (!musd.transfer(to, amount)) revert TransferFailed();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
