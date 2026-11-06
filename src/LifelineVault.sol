// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves, IMUSDSavings} from "./interfaces/IMezo.sol";

/// @title LifelineVault (Lifeline: auto-rescue for MUSD troves)
/// @notice A smart account that owns ONE mUSD trove on Mezo and protects it from liquidation.
///         The owner parks a BTC and/or MUSD "rescue reserve" inside the vault and sets a policy
///         (trigger ICR, target ICR, keeper tip). When the trove's collateral ratio falls below the
///         trigger, ANYONE may call `protect()`: the vault tops up collateral from the BTC reserve
///         and/or repays debt from the MUSD reserve in one `BorrowerOperations.adjustTrove` until the
///         trove is back at the target ratio, and pays the caller a small capped tip.
///         MUSD liquidates a trove only when its ICR is below 110% (MCR), in normal mode and in
///         Recovery Mode. Recovery Mode (system TCR below 150%) restricts new borrowing; it does not
///         widen liquidations. Optional redemption guard: also rescue when too little other MUSD debt
///         sits ahead of this trove in the redemption queue.
///         Idle MUSD above `liquidMusdFloor` can be deposited to Mezo's MUSD Savings Vault (sMUSD).
///         sMUSD is 1:1 principal. Yield the savings vault has already credited is claimed before a
///         rescue is sized, so the share balance is not treated as the whole MUSD redemption value.
///         Keepers can never withdraw, borrow, or move funds anywhere except into the owner's trove
///         (or into sMUSD still held by this vault, and only above the liquid floor).
contract LifelineVault {
    // ---- protocol constants (mirroring mUSD) ----
    uint256 public constant MCR = 1.1e18; // 110%: a trove is liquidatable only below this, in every mode
    uint256 public constant CCR = 1.5e18; // 150%: system enters Recovery Mode below this TCR. Not a liquidation line.
    uint256 public constant GAS_COMPENSATION = 200e18; // MUSD reserved for liquidators
    uint256 public constant MAX_TIP_BPS = 200; // keeper tip can never exceed 2% of the rescue size
    uint256 public constant MAX_REDEMPTION_ICR = 2.5e18; // redemption guard never chases the queue above 250%
    uint256 public constant REDEMPTION_MARGIN = 0.02e18; // sit 2 points above the last trove in the buffer
    uint256 public constant REDEMPTION_HYSTERESIS = 0.01e18; // rescue overshoots the safe ICR by 1 point
    uint256 public constant MAX_QUEUE_STEPS = 60; // bound on the SortedTroves walk
    /// @notice Hard minimum MUSD that must stay liquid. The owner cannot set the floor below this.
    uint256 public constant MIN_LIQUID_MUSD = 100e18;

    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IERC20Min public immutable musd;
    ISortedTroves public immutable sortedTroves;
    /// @notice Mezo MUSD Savings Rate this vault deposits into. Set by the factory.
    IMUSDSavings public immutable savings;
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
    /// @notice MUSD that must stay liquid (not in sMUSD). Default is max, so nothing is deployed
    ///         until the owner sets an explicit floor. Cannot be set below `MIN_LIQUID_MUSD`.
    ///         `protect()` may still recall sMUSD to repay.
    uint256 public liquidMusdFloor = type(uint256).max;
    /// @notice Max sMUSD principal this vault may hold. 0 disables deployment.
    uint256 public savingsCap;
    /// @notice Circuit breaker for new savings deposits. Recall and `protect()` keep working.
    bool public savingsPaused = true;
    uint256 private _locked = 1;

    event PolicyUpdated(
        uint256 triggerICR, uint256 targetICR, uint256 tipBps, uint256 maxTipWei, uint256 redemptionBufferMusd
    );
    event TroveOpened(uint256 collateral, uint256 debt);
    event ReserveFunded(address indexed from, uint256 btc, uint256 musdAmount);
    event ReserveWithdrawn(uint256 btc, uint256 musdAmount);
    event LiquidFloorUpdated(uint256 floor);
    event SavingsCapUpdated(uint256 cap);
    event SavingsPausedSet(bool paused);
    event SavingsDeployed(uint256 musdDeposited, uint256 smusdBalance);
    event SavingsRecalled(uint256 smusdBurned);
    event SavingsYieldClaimed(uint256 musdAmount);
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
    error SavingsMismatch();
    error SavingsPaused();
    error FloorBelowMinimum(uint256 floor);

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
        IMUSDSavings _savings,
        Policy memory _policy
    ) {
        owner = _owner;
        factory = msg.sender;
        borrowerOperations = _bo;
        troveManager = _tm;
        priceFeed = _pf;
        musd = _musd;
        sortedTroves = _sortedTroves;
        savings = _savings;
        if (address(_savings) == address(0) || _savings.musdToken() != address(_musd)) revert SavingsMismatch();
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
    ///         sMUSD is withdrawn first so principal (and any real claimable yield) is included.
    function closeTrove() external onlyOwner nonReentrant {
        _recallAllSavings();
        (uint256 debt,) = _debtAndColl();
        uint256 needed = debt - GAS_COMPENSATION;
        uint256 have = musd.balanceOf(address(this));
        if (have < needed) {
            if (!musd.transferFrom(msg.sender, address(this), needed - have)) revert TransferFailed();
        }
        borrowerOperations.closeTrove();
        _sweep();
    }

    /// @notice Claim surplus collateral after a liquidation or full redemption, and sweep everything.
    function claimAndSweep() external onlyOwner nonReentrant {
        _recallAllSavings();
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

    /// @notice MUSD that `deployExcessMusd` must leave liquid. Only the owner can change it,
    ///         and it cannot be set below `MIN_LIQUID_MUSD`.
    function setLiquidMusdFloor(uint256 floor) external onlyOwner {
        if (floor < MIN_LIQUID_MUSD) revert FloorBelowMinimum(floor);
        liquidMusdFloor = floor;
        emit LiquidFloorUpdated(floor);
    }

    /// @notice Cap on sMUSD principal this vault will hold. Only the owner.
    function setSavingsCap(uint256 cap) external onlyOwner {
        savingsCap = cap;
        emit SavingsCapUpdated(cap);
    }

    /// @notice Stop or resume new deposits into the savings vault. Does not block recall or `protect()`.
    function setSavingsPaused(bool paused) external onlyOwner {
        savingsPaused = paused;
        emit SavingsPausedSet(paused);
    }

    /// @notice Deposit liquid MUSD above `liquidMusdFloor` into the MUSD Savings Vault, up to `savingsCap`.
    ///         Holds sMUSD. Callable by anyone. Reverts while paused. Returns 0 when there is no room.
    ///         Principal is 1:1. This does not report or simulate an APY.
    function deployExcessMusd() external nonReentrant returns (uint256 deposited) {
        if (savingsPaused) revert SavingsPaused();
        uint256 staked = stakedMusd();
        uint256 room = savingsCap > staked ? savingsCap - staked : 0;
        uint256 liquid = musd.balanceOf(address(this));
        uint256 excess = liquid > liquidMusdFloor ? liquid - liquidMusdFloor : 0;
        deposited = excess < room ? excess : room;
        if (deposited == 0) return 0;
        _approveMusd(address(savings), deposited);
        savings.deposit(deposited);
        emit SavingsDeployed(deposited, stakedMusd());
    }

    /// @notice Pull sMUSD principal back to liquid MUSD. The savings vault also pays any yield it
    ///         has actually credited. Owner only; keepers recall only inside `protect()`.
    function recallSavings(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) return;
        savings.withdraw(amount);
        emit SavingsRecalled(amount);
    }

    /// @notice Claim savings yield the protocol has already distributed. Returns 0 when none is due.
    function claimSavingsYield() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = savings.claimYield();
        if (amount > 0) emit SavingsYieldClaimed(amount);
    }

    // ------------------------------------------------------------------
    // Permissionless: protection
    // ------------------------------------------------------------------

    /// @notice Rescue the trove if it is below its trigger. Callable by anyone.
    ///         Collateral and repayment are applied in one `adjustTrove`, so a mixed BTC+MUSD
    ///         rescue that is still under 110% after either leg alone does not revert.
    /// @return collAdded BTC moved from reserve into the trove
    /// @return musdRepaid MUSD from reserve used to repay debt
    /// @return tip BTC paid to msg.sender (Lifeline's fee; capped by policy and by MAX_TIP_BPS)
    function protect(address upperHint, address lowerHint)
        external
        nonReentrant
        returns (uint256 collAdded, uint256 musdRepaid, uint256 tip)
    {
        if (troveManager.getTroveStatus(address(this)) != 1) revert NoActiveTrove();
        uint256 price = priceFeed.fetchPrice();
        bool rm = troveManager.checkRecoveryMode(price);
        (uint256 trigger, uint256 target) = effectiveThresholds();
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
        uint256 liquidMusd = musd.balanceOf(address(this));
        if (collAdded < collNeeded) {
            // sMUSD balanceOf is principal, not the MUSD a rescue can raise after yield
            // has accrued. Claim what the savings vault has already credited, then count
            // liquid MUSD plus 1:1 principal. Do not price sMUSD on a market.
            _realizeSavingsYield();
            liquidMusd = musd.balanceOf(address(this));
            uint256 shares = stakedMusd();
            uint256 bal = liquidMusd + shares;
            // debt the trove can carry at the target ratio with the new collateral
            uint256 maxDebt = (newColl * price) / target;
            uint256 want = debt > maxDebt ? debt - maxDebt : 0;
            // mUSD rules: net debt (debt - gas comp) must stay >= minNetDebt
            uint256 floor = borrowerOperations.minNetDebt() + GAS_COMPENSATION;
            uint256 room = debt > floor ? debt - floor : 0;
            musdRepaid = _min(want, _min(room, bal));
            newDebt = debt - musdRepaid;
        }

        // Liquidation is ICR < 110% in every mode, including Recovery Mode.
        // A rescue that cannot clear that line reverts so keepers don't spend a partial one.
        uint256 reachable = newDebt == 0 ? type(uint256).max : (newColl * price) / newDebt;
        if (reachable <= MCR) revert ReserveTooSmall(reachable);
        if (collAdded == 0 && musdRepaid == 0) revert ReserveTooSmall(reachable);

        // 2) Pull sMUSD principal back if the liquid MUSD balance is short, then one adjustTrove.
        //    Split addColl + repayMUSD reverts in normal mode when each leg is still under 110%.
        if (musdRepaid > liquidMusd) {
            uint256 pull = musdRepaid - liquidMusd;
            // `withdraw` burns this many sMUSD and returns that much principal.
            // It is not an ERC-4626 asset withdrawal. Yield was already claimed.
            savings.withdraw(pull);
            emit SavingsRecalled(pull);
        }
        borrowerOperations.adjustTrove{value: collAdded}(0, musdRepaid, false, upperHint, lowerHint);

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

    /// @notice The owner's trigger and target. Recovery Mode does not rewrite them: MUSD liquidates
    ///         only below MCR (110%) in every mode. CCR still gates new borrowing while TCR < 150%.
    function effectiveThresholds() public view returns (uint256 trigger, uint256 target) {
        return (policy.triggerICR, policy.targetICR);
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
        uint256 liquidationPrice; // BTC price at which ICR == MCR (110%), in every mode
        uint256 redemptionSafeICR; // 0 if the redemption guard is off
        bool redemptionRisk; // ICR below redemptionSafeICR
    }

    function health() external view returns (Health memory h) {
        h.status = troveManager.getTroveStatus(address(this));
        h.price = priceFeed.fetchPrice();
        h.recoveryMode = troveManager.checkRecoveryMode(h.price);
        (h.trigger, h.target) = effectiveThresholds();
        h.reserveBtc = address(this).balance;
        h.reserveMusd = musd.balanceOf(address(this)) + savingsMusd();
        if (h.status == 1) {
            (h.debt, h.coll) = _debtAndColl();
            h.icr = troveManager.getCurrentICR(address(this), h.price);
            h.redemptionSafeICR = redemptionSafeICR(h.price);
            h.redemptionRisk = h.redemptionSafeICR != 0 && h.icr < h.redemptionSafeICR;
            h.needsProtection = h.icr < h.trigger || h.redemptionRisk;
            h.liquidationPrice = h.coll == 0 ? 0 : (MCR * h.debt) / h.coll;
        }
    }

    /// @notice sMUSD this vault holds. That is principal: 1 sMUSD withdraws 1 MUSD.
    ///         Credited yield is not part of this balance. See `unclaimedSavingsYield`.
    function stakedMusd() public view returns (uint256) {
        return _staticUint(abi.encodeWithSignature("balanceOf(address)", address(this)));
    }

    /// @notice Yield the savings vault has already credited to this vault and not yet paid.
    ///         Stored `claimableYield` plus the pending `yieldIndex` delta. Zero when the
    ///         savings vault does not implement that accounting.
    function unclaimedSavingsYield() public view returns (uint256) {
        return _pendingSavingsYield(stakedMusd());
    }

    /// @notice MUSD this vault can take back from savings: 1:1 principal plus credited yield.
    ///         Liquid MUSD already in this contract is not included. No sMUSD market price.
    function savingsMusd() public view returns (uint256) {
        uint256 shares = stakedMusd();
        return shares + _pendingSavingsYield(shares);
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

    function _recallAllSavings() internal {
        uint256 s = stakedMusd();
        if (s == 0) return;
        savings.withdraw(s);
        emit SavingsRecalled(s);
    }

    /// @dev Match `MUSDSavingsRate.withdraw`: pull strategy yield into the index, then claim.
    ///      A failed claim must not block a rescue that the 1:1 principal can still fund.
    function _realizeSavingsYield() internal {
        uint256 shares = stakedMusd();
        uint256 stored = _staticUint(abi.encodeWithSignature("claimableYield(address)", address(this)));
        if (shares == 0 && stored == 0) return;
        try savings.receiveYieldFromStrategy() {} catch {}
        if (_pendingSavingsYield(stakedMusd()) == 0) return;
        try savings.claimYield() returns (uint256 amount) {
            if (amount > 0) emit SavingsYieldClaimed(amount);
        } catch {}
    }

    /// @dev Same split `MUSDSavingsRate._updateYieldFor` uses. `claimableYield` alone is stale
    ///      until the next transfer, claim, or withdraw.
    function _pendingSavingsYield(uint256 shares) internal view returns (uint256) {
        uint256 stored = _staticUint(abi.encodeWithSignature("claimableYield(address)", address(this)));
        if (shares == 0) return stored;
        uint256 index = _staticUint(abi.encodeWithSignature("yieldIndex()"));
        uint256 userIndex = _staticUint(abi.encodeWithSignature("supplyYieldIndex(address)", address(this)));
        if (index <= userIndex) return stored;
        return stored + (shares * (index - userIndex)) / 1e18;
    }

    function _staticUint(bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(savings).staticcall(data);
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _approveMusd(address spender, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(musd).call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
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
