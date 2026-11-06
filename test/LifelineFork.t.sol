// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LifelineVault} from "../src/LifelineVault.sol";
import {LifelineFactory} from "../src/LifelineFactory.sol";
import {ExternalKeeper} from "../src/ExternalKeeper.sol";
import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves, IMUSDSavings} from "../src/interfaces/IMezo.sol";

/// Fork tests against the REAL mUSD deployment on Mezo testnet (chain 31611).
/// The only thing mocked is PriceFeed.fetchPrice(): Mezo's oracle is a chain precompile that a local
/// fork cannot execute, and we need to move the BTC price to simulate a crash anyway.
contract LifelineForkTest is Test {
    // Mezo testnet (matsnet) addresses from github.com/mezo-org/musd/solidity/deployments/matsnet
    IBorrowerOperations constant BO = IBorrowerOperations(0xCdF7028ceAB81fA0C6971208e83fa7872994beE5);
    ITroveManager constant TM = ITroveManager(0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0);
    IPriceFeed constant PF = IPriceFeed(0x86bCF0841622a5dAC14A313a15f96A95421b9366);
    IERC20Min constant MUSD = IERC20Min(0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503);
    ISortedTroves constant ST = ISortedTroves(0x722E4D24FD6Ff8b0AC679450F3D91294607268fA);
    IMUSDSavings constant SAVINGS = IMUSDSavings(0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16);

    uint256 constant P0 = 84_000e18; // starting BTC price
    LifelineFactory factory;
    LifelineVault vault;
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.createSelectFork("mezo_testnet");
        setPrice(P0);
        factory = new LifelineFactory(BO, TM, PF, MUSD, ST, SAVINGS);
        vm.deal(alice, 10 ether); // "ether" = 1e18 units of native BTC on Mezo
        vm.prank(alice);
        vault = factory.createVault(
            LifelineVault.Policy({triggerICR: 1.3e18, targetICR: 1.6e18, tipBps: 50, maxTipWei: 0.0005 ether, redemptionBufferMusd: 0})
        );
        // 0.06 BTC (~$5,040) collateral, 2,000 MUSD debt (+200 gas comp + fee) -> ICR ~ 228%
        vm.prank(alice);
        vault.openTrove{value: 0.06 ether}(0.06 ether, 2_000e18, address(0), address(0));
    }

    function setPrice(uint256 p) internal {
        vm.mockCall(address(PF), abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(p));
    }

    function icr() internal view returns (uint256) {
        return TM.getCurrentICR(address(vault), PF.fetchPrice());
    }

    function _debtColl() internal view returns (uint256 debt, uint256 coll) {
        (uint256 c, uint256 pr, uint256 i,,,) = TM.getEntireDebtAndColl(address(vault));
        coll = c;
        debt = pr + i;
    }

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ---------------------------------------------------------------- basics

    function test_OpenTrove_vaultIsBorrowerAndOwnerGetsMUSD() public view {
        assertEq(TM.getTroveStatus(address(vault)), 1, "trove active");
        assertEq(MUSD.balanceOf(alice), 2_000e18, "owner received borrowed MUSD");
        assertGt(icr(), 2.2e18);
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultsOfOwner(alice)[0], address(vault));
    }

    function test_Protect_revertsWhenHealthy() public {
        vm.deal(address(vault), 0.05 ether);
        vm.prank(keeper);
        vm.expectRevert();
        vault.protect(address(0), address(0));
    }

    // ---------------------------------------------------------------- the core story

    function test_CrashWithoutGuardianGetsLiquidated_withGuardianSurvives() public {
        // Twin trove opened directly (no guardian) with the same shape.
        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        BO.openTrove{value: 0.05 ether}(2_000e18, address(0), address(0));

        // Alice runs the same shape (0.05 BTC / 2,000 MUSD) and funds a BTC rescue reserve.
        vm.startPrank(alice);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        vault.fundReserve{value: 0.04 ether}(0);
        vm.stopPrank();

        // BTC crashes 45%: both troves fall to ~105%, under the 110% MCR. System stays in Normal Mode.
        setPrice((P0 * 55) / 100);
        assertFalse(TM.checkRecoveryMode(PF.fetchPrice()));
        assertLt(icr(), 1.1e18, "alice is liquidatable before the keeper acts");

        vm.prank(keeper);
        (uint256 added,, uint256 tip) = vault.protect(address(0), address(0));
        assertGt(added, 0);
        assertGt(tip, 0);
        assertEq(keeper.balance, tip, "keeper paid");
        assertApproxEqRel(icr(), 1.6e18, 0.001e18, "restored to target");

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        TM.liquidate(bob); // Bob's unguarded trove gets liquidated
        assertEq(TM.getTroveStatus(bob), 3, "bob liquidated");

        vm.prank(liquidator);
        vm.expectRevert(); // Alice's guarded trove cannot be liquidated
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1, "alice still active");
    }

    function test_Protect_usesMUSDReserveWhenNoBTC() public {
        // Alice borrows more and parks MUSD as the reserve instead of BTC.
        vm.startPrank(alice);
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.fundReserve(1_000e18);
        vm.stopPrank();

        setPrice((P0 * 55) / 100); // ICR ~126%, under the 130% trigger
        uint256 before = icr();
        assertLt(before, 1.3e18);

        vm.prank(keeper);
        (uint256 added, uint256 repaid,) = vault.protect(address(0), address(0));
        assertEq(added, 0, "no BTC to add");
        assertGt(repaid, 0, "repaid with MUSD");
        assertGt(icr(), 1.3e18, "out of danger");
    }

    function test_RecoveryMode_liquidatesOnlyBelow110() public {
        // Bob matches Alice. Then pick a price that puts Bob under 110% and the system under 150% TCR.
        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        BO.openTrove{value: 0.06 ether}(2_000e18, address(0), address(0));
        uint256 bobIcr0 = TM.getCurrentICR(bob, P0);
        uint256 p = (P0 * 1.05e18) / bobIcr0;

        // Top Alice up so she sits around 125% at that price: under 150%, above the 110% liquidation line.
        (uint256 debt, uint256 coll) = _debtColl();
        uint256 wantColl = (1.25e18 * debt) / p + 1;
        vm.prank(alice);
        vault.addColl{value: wantColl - coll}(address(0), address(0));
        setPrice(p);

        assertTrue(TM.checkRecoveryMode(p), "system in recovery mode");
        assertLt(TM.getCurrentICR(bob, p), 1.1e18, "bob is under 110%");
        uint256 ratio = icr();
        assertGt(ratio, 1.1e18, "alice is above the liquidation line");
        assertLt(ratio, 1.5e18, "alice is under the old 150% recovery-mode line");

        (uint256 trig, uint256 tgt) = vault.effectiveThresholds();
        assertEq(trig, 1.3e18, "owner trigger is not rewritten in recovery mode");
        assertEq(tgt, 1.6e18);
        LifelineVault.Health memory h = vault.health();
        assertTrue(h.recoveryMode);
        assertApproxEqRel(h.liquidationPrice, (1.1e18 * h.debt) / h.coll, 1e14);

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert();
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1, "125% trove survives recovery mode");

        vm.prank(liquidator);
        TM.liquidate(bob);
        assertEq(TM.getTroveStatus(bob), 3, "under 110% is liquidated in recovery mode");
    }

    function test_Protect_mixedAssetsBelow110_singleAdjustTrove() public {
        // Leave the trove near 105% in normal mode, with a BTC slice and an MUSD slice that each
        // miss 110% on their own. Together they clear it. Split addColl/repayMUSD reverts.
        vm.prank(alice);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        uint256 price = (P0 * 55) / 100;
        setPrice(price);
        assertFalse(TM.checkRecoveryMode(price));
        (uint256 debt, uint256 coll) = _debtColl();
        assertLt((coll * price) / debt, 1.1e18);

        uint256 collFor109 = _ceil(1.09e18 * debt, price);
        uint256 btcPiece = collFor109 - coll;
        uint256 debtFor109 = (coll * price) / 1.09e18;
        uint256 musdPiece = debt - debtFor109;
        assertGt(btcPiece, 0);
        assertGt(musdPiece, 0);
        assertLt(((coll + btcPiece) * price) / debt, 1.1e18, "BTC leg alone stays under 110%");
        assertLt((coll * price) / (debt - musdPiece), 1.1e18, "MUSD leg alone stays under 110%");
        assertGt(((coll + btcPiece) * price) / (debt - musdPiece), 1.1e18, "both legs clear 110%");

        uint256 snap = vm.snapshotState();
        vm.deal(address(vault), btcPiece);
        vm.prank(address(vault));
        (bool addOk,) = address(BO).call{value: btcPiece}(
            abi.encodeWithSignature("addColl(address,address)", address(0), address(0))
        );
        assertFalse(addOk, "addColl alone reverts under 110%");
        vm.revertToState(snap);

        deal(address(MUSD), address(vault), musdPiece);
        vm.prank(address(vault));
        (bool repayOk,) = address(BO).call(
            abi.encodeWithSignature("repayMUSD(uint256,address,address)", musdPiece, address(0), address(0))
        );
        assertFalse(repayOk, "repayMUSD alone reverts under 110%");
        vm.revertToState(snap);

        vm.deal(address(vault), btcPiece + 0.0005 ether); // tip cap stays out of the collateral budget
        deal(address(MUSD), address(vault), musdPiece);
        vm.prank(keeper);
        (uint256 added, uint256 repaid,) = vault.protect(address(0), address(0));
        assertEq(added, btcPiece, "whole BTC slice went in");
        assertEq(repaid, musdPiece, "whole MUSD slice repaid");
        assertGt(icr(), 1.1e18, "single adjustTrove cleared 110%");

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert();
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1);
    }

    function test_Protect_repaysMUSDBelow110_andSurvivesLiquidation() public {
        vm.startPrank(alice);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.fundReserve(1_500e18);
        vm.stopPrank();

        setPrice((P0 * 55) / 100);
        assertLt(icr(), 1.1e18, "liquidatable before the keeper");
        assertEq(address(vault).balance, 0, "no BTC reserve");

        vm.prank(keeper);
        (uint256 added, uint256 repaid,) = vault.protect(address(0), address(0));
        assertEq(added, 0);
        assertGt(repaid, 0, "repaid with MUSD");
        assertGt(icr(), 1.1e18, "out of liquidation range");

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert();
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1);
    }

    function test_ExternalKeeper_repaysMUSDBelow110() public {
        ExternalKeeper bot = new ExternalKeeper(keeper);
        vm.startPrank(alice);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.fundReserve{value: 0.0001 ether}(1_500e18);
        vm.stopPrank();

        setPrice((P0 * 55) / 100);
        assertLt(icr(), 1.1e18, "liquidatable before the external keeper");

        vm.prank(keeper);
        (uint256 added, uint256 repaid, uint256 tip) = bot.rescue(vault, address(0), address(0));
        assertEq(added, 0, "BTC reserve was only the tip budget");
        assertGt(repaid, 0, "external contract repaid MUSD");
        assertGt(tip, 0);
        assertEq(address(bot).balance, tip, "tip paid to the external keeper");
        assertGt(icr(), 1.1e18);

        vm.prank(mallory);
        vm.expectRevert(ExternalKeeper.NotOperator.selector);
        bot.withdrawTip(payable(mallory));
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        bot.withdrawTip(payable(keeper));
        assertEq(keeper.balance, keeperBefore + tip);

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert();
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1);
    }

    function test_Savings_deploysExcessAboveFloor_andProtectRecallsIt() public {
        assertEq(SAVINGS.musdToken(), address(MUSD), "savings vault is the matsnet MUSD one");
        vm.startPrank(alice);
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.fundReserve(1_000e18);
        vm.stopPrank();

        // Paused by default, so a keeper cannot move the reserve even after it is funded.
        vm.expectRevert(LifelineVault.SavingsPaused.selector);
        vault.deployExcessMusd();
        assertEq(MUSD.balanceOf(address(vault)), 1_000e18);

        vm.prank(mallory);
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.setLiquidMusdFloor(200e18);
        vm.prank(mallory);
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.setSavingsPaused(false);
        vm.prank(mallory);
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.recallSavings(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LifelineVault.FloorBelowMinimum.selector, uint256(0)));
        vault.setLiquidMusdFloor(0);
        vm.prank(alice);
        vault.setLiquidMusdFloor(200e18);

        // Paused by default, and the cap starts at 0. Both block deployment.
        vm.expectRevert(LifelineVault.SavingsPaused.selector);
        vault.deployExcessMusd();
        vm.prank(alice);
        vault.setSavingsPaused(false);
        assertEq(vault.deployExcessMusd(), 0, "cap is 0");
        vm.prank(alice);
        vault.setSavingsCap(100e18);
        assertEq(vault.deployExcessMusd(), 100e18, "cap binds");
        vm.prank(alice);
        vault.setSavingsCap(800e18);
        uint256 deployed = vault.deployExcessMusd();
        assertEq(deployed, 700e18);
        assertEq(vault.stakedMusd(), 800e18, "vault holds sMUSD");
        assertEq(SAVINGS.balanceOf(address(vault)), 800e18);
        assertEq(MUSD.balanceOf(address(vault)), 200e18, "floor stayed liquid");
        vm.prank(alice);
        vault.setSavingsPaused(true);
        vm.expectRevert(LifelineVault.SavingsPaused.selector);
        vault.deployExcessMusd();
        vm.prank(alice);
        vault.setSavingsPaused(false);
        assertEq(vault.deployExcessMusd(), 0, "cannot deploy the floor");
        // Exercise the real claim path. A fresh deposit often has nothing credited; do not require yield.
        vm.prank(alice);
        vault.claimSavingsYield();

        // Drop under the 130% trigger but keep the trove above 110%, and give it no BTC reserve.
        // Repaying up to 160% needs more than the 200 MUSD floor, so protect must recall sMUSD.
        // The circuit breaker stays shut: recall for a rescue is not a new deposit.
        vm.prank(alice);
        vault.setSavingsPaused(true);
        setPrice((P0 * 55) / 100);
        assertGt(icr(), 1.1e18);
        assertLt(icr(), 1.3e18);
        uint256 stakedBefore = vault.stakedMusd();
        vm.prank(keeper);
        (uint256 added, uint256 repaid,) = vault.protect(address(0), address(0));
        assertEq(added, 0);
        assertGt(repaid, 200e18, "repay used more than the liquid floor");
        assertLt(vault.stakedMusd(), stakedBefore, "sMUSD was recalled into the trove");
        assertGt(icr(), 1.3e18);
    }

    /// @notice Real MUSD Savings Rate yield: the index moves and the sMUSD balance does not.
    ///         Share-balance accounting cannot clear 110%. Claiming the credited yield can.
    function test_Protect_accruedSavingsYieldClearsLineSharesCannot() public {
        uint256 shares = 20e18;
        _parkSavingsPrincipal(shares);
        _creditProtocolYield(100e18);
        assertEq(vault.stakedMusd(), shares, "yield does not mint sMUSD");
        assertEq(MUSD.balanceOf(address(vault)), 0, "principal is in sMUSD, yield is not liquid yet");
        uint256 yield = vault.unclaimedSavingsYield();
        assertGt(yield, 1e18, "protocol yield was credited to this vault");
        assertEq(vault.savingsMusd(), shares + yield);
        assertEq(vault.health().reserveMusd, shares + yield, "backing includes credited yield, not a market price");

        (uint256 debt, uint256 coll) = _debtColl();
        uint256 floorDebt = BO.minNetDebt() + vault.GAS_COMPENSATION();
        uint256 room = debt - floorDebt;
        assertGt(room, shares, "there is repay room the share balance does not fill");
        uint256 repayNew = shares + yield < room ? shares + yield : room;
        assertGt(repayNew, shares);

        // Price where repaying only the share balance lands on 110% (old code reverts:
        // reachable <= MCR) and repaying principal plus credited yield clears it.
        uint256 price = (vault.MCR() * (debt - shares)) / coll;
        setPrice(price);
        uint256 oldReach = (coll * price) / (debt - shares);
        uint256 newReach = (coll * price) / (debt - repayNew);
        assertLe(oldReach, vault.MCR(), "old accounting cannot clear 110%");
        assertGt(newReach, vault.MCR(), "credited yield can clear 110%");
        assertLt(icr(), vault.MCR(), "liquidatable before the keeper");

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        (, uint256 repaid,) = vault.protect(address(0), address(0));
        assertGt(repaid, shares, "repay used credited yield, not just the sMUSD balance");
        assertEq(vault.unclaimedSavingsYield(), 0, "yield was claimed into the rescue");
        assertGt(icr(), vault.MCR());
        _assertSurvivesLiquidation();

        vm.revertToState(snap);
        ExternalKeeper bot = new ExternalKeeper(keeper);
        vm.prank(keeper);
        (, repaid,) = bot.rescue(vault, address(0), address(0));
        assertGt(repaid, shares, "external keeper rescue uses the same yield");
        assertEq(address(bot).balance, 0, "no BTC was left to tip");
        assertGt(icr(), vault.MCR());
        _assertSurvivesLiquidation();
    }

    function _parkSavingsPrincipal(uint256 shares) internal {
        vm.startPrank(alice);
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.fundReserve(shares + vault.MIN_LIQUID_MUSD());
        vault.setLiquidMusdFloor(vault.MIN_LIQUID_MUSD());
        vault.setSavingsPaused(false);
        vault.setSavingsCap(shares);
        assertEq(vault.deployExcessMusd(), shares);
        vault.withdrawReserve(0, vault.MIN_LIQUID_MUSD());
        vault.setSavingsPaused(true);
        vm.stopPrank();
        assertEq(address(vault).balance, 0, "no BTC reserve");
        assertEq(MUSD.balanceOf(address(vault)), 0);
        assertEq(vault.stakedMusd(), shares);
        assertEq(address(vault.savings()), address(SAVINGS));
    }

    /// @dev `receiveProtocolYield` is the live vault's distribution path. The sMUSD supply
    ///      is the whole testnet's, so the donation is sized off that supply. Fork only.
    function _creditProtocolYield(uint256 wantYield) internal {
        uint256 supply = SAVINGS.totalSupply();
        uint256 shares = vault.stakedMusd();
        uint256 amount = (wantYield * supply) / shares + supply;
        address donor = makeAddr("yieldDonor");
        deal(address(MUSD), donor, amount);
        vm.startPrank(donor);
        MUSDapprove(donor, address(SAVINGS), amount);
        SAVINGS.receiveProtocolYield(amount);
        vm.stopPrank();
    }

    function _assertSurvivesLiquidation() internal {
        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert();
        TM.liquidate(address(vault));
        assertEq(TM.getTroveStatus(address(vault)), 1);
    }

    function test_Protect_revertsIfReserveCannotSave() public {
        vm.startPrank(alice);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        vault.fundReserve{value: 0.0006 ether}(0); // basically just the tip cap
        vm.stopPrank();
        setPrice((P0 * 55) / 100); // ICR ~105%: 0.0001 BTC of usable reserve cannot lift it over 110%
        vm.prank(keeper);
        vm.expectPartialRevert(LifelineVault.ReserveTooSmall.selector);
        vault.protect(address(0), address(0));
    }

    // ---------------------------------------------------------------- safety

    function test_OnlyOwnerCanMoveFunds() public {
        vm.deal(address(vault), 0.05 ether);
        vm.startPrank(mallory);
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.withdrawReserve(0.05 ether, 0);
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.borrow(100e18, address(0), address(0));
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.withdrawColl(0.01 ether, address(0), address(0));
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.closeTrove();
        vm.expectRevert(LifelineVault.NotOwner.selector);
        vault.setPolicy(LifelineVault.Policy(1.2e18, 1.5e18, 0, 0, 0));
        vm.stopPrank();
    }

    function test_TipIsCapped() public {
        vm.prank(alice);
        vault.fundReserve{value: 1 ether}(0);
        setPrice((P0 * 52) / 100);
        vm.prank(keeper);
        (,, uint256 tip) = vault.protect(address(0), address(0));
        assertLe(tip, 0.0005 ether);
    }

    function test_BadPolicyRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(LifelineVault.BadPolicy.selector);
        vault.setPolicy(LifelineVault.Policy(1.05e18, 1.5e18, 0, 0, 0)); // trigger under MCR
        vm.expectRevert(LifelineVault.BadPolicy.selector);
        vault.setPolicy(LifelineVault.Policy(1.4e18, 1.3e18, 0, 0, 0)); // target <= trigger
        vm.expectRevert(LifelineVault.BadPolicy.selector);
        vault.setPolicy(LifelineVault.Policy(1.3e18, 1.6e18, 500, 0, 0)); // tip > 2%
        vm.stopPrank();
    }

    function test_FactoryScanFindsAtRiskVaults() public {
        vm.prank(alice);
        vault.fundReserve{value: 0.04 ether}(0);
        assertEq(factory.scan(0, 10).length, 0);
        setPrice((P0 * 52) / 100);
        address[] memory hits = factory.scan(0, 10);
        assertEq(hits.length, 1);
        assertEq(hits[0], address(vault));
        vm.prank(keeper);
        vault.protect(address(0), address(0));
        assertEq(factory.scan(0, 10).length, 0);
    }

    function test_HealthView() public view {
        LifelineVault.Health memory h = vault.health();
        assertEq(h.status, 1);
        assertEq(h.price, P0);
        assertFalse(h.needsProtection);
        // liquidation price = 1.1 * debt / coll
        assertApproxEqRel(h.liquidationPrice, (1.1e18 * h.debt) / h.coll, 1e12);
        assertLt(h.liquidationPrice, P0);
    }

    function test_CloseTrove_returnsEverything() public {
        vm.prank(alice);
        vault.fundReserve{value: 0.01 ether}(0);
        // Alice needs debt-200 MUSD; she has 2,000 from the loan; fee+interest top-up from a friend.
        deal(address(MUSD), alice, 3_000e18);
        uint256 btcBefore = alice.balance;
        vm.startPrank(alice);
        MUSDapprove(alice, address(vault), type(uint256).max);
        vault.closeTrove();
        vm.stopPrank();
        assertEq(TM.getTroveStatus(address(vault)), 2, "closed by owner");
        assertEq(address(vault).balance, 0);
        assertEq(alice.balance, btcBefore + 0.07 ether, "collateral + reserve returned");
    }

    function test_WithdrawCollAndBorrowGoToOwner() public {
        uint256 b0 = alice.balance;
        vm.startPrank(alice);
        vault.withdrawColl(0.005 ether, address(0), address(0));
        vault.borrow(100e18, address(0), address(0));
        vm.stopPrank();
        assertEq(alice.balance, b0 + 0.005 ether);
        assertEq(MUSD.balanceOf(alice), 2_100e18);
    }

    // ---------------------------------------------------------------- redemption guard

    function _setRedemptionGuard(uint128 buffer) internal {
        vm.prank(alice);
        vault.setPolicy(LifelineVault.Policy(1.2e18, 1.3e18, 50, 0.0005 ether, buffer));
    }

    function test_RedemptionGuard_offByDefault() public view {
        assertEq(vault.redemptionSafeICR(P0), 0);
    }

    function test_RedemptionGuard_movesTroveBehindTheQueue_andRedemptionHitsOthers() public {
        // Sit just above 112% so Alice is at the front of the live queue. The testnet list moves,
        // so the redemption size is "debt already in front, plus 5,000 MUSD" rather than a fixed 20k
        // that no longer reaches a 127% trove.
        (uint256 debt, uint256 coll) = _debtColl();
        uint256 want = (1.12e18 * debt) / P0 + 1;
        vm.startPrank(alice);
        vault.withdrawColl(coll - want, address(0), address(0));
        vault.fundReserve{value: 0.05 ether}(0);
        vm.stopPrank();
        uint256 before = icr();
        assertGt(before, 1.11e18);
        assertLt(before, 1.2e18);

        uint256 ahead = _debtAheadOf(before);
        uint256 redeemAmt = ahead + 5_000e18;
        uint128 buffer = uint128(ahead + 15_000e18);
        address redeemer = makeAddr("redeemer");
        deal(address(MUSD), redeemer, redeemAmt);

        // Control: WITHOUT the guard, that redemption takes some of Alice's BTC.
        uint256 snap = vm.snapshotState();
        (uint256 c0,,,,,) = TM.getEntireDebtAndColl(address(vault));
        vm.prank(redeemer);
        TM.redeemCollateral(redeemAmt, address(0), address(0), address(0), 0, 0);
        (uint256 c1,,,,,) = TM.getEntireDebtAndColl(address(vault));
        assertLt(c1, c0, "control: unguarded, Alice gets redeemed");
        vm.revertToState(snap);

        vm.prank(alice);
        vault.setPolicy(LifelineVault.Policy(1.111e18, 1.25e18, 50, 0.0005 ether, buffer));
        uint256 safe = vault.redemptionSafeICR(P0);
        assertGt(safe, before, "guard says: too close to the front of the queue");
        assertTrue(vault.health().redemptionRisk);
        assertEq(factory.scan(0, 10).length, 1, "keepers see it");

        vm.prank(keeper);
        (uint256 added,,) = vault.protect(address(0), address(0));
        assertGt(added, 0);
        assertGe(icr(), safe, "lifted just past the buffer");
        assertFalse(vault.health().redemptionRisk);
        assertEq(factory.scan(0, 10).length, 0, "no re-trigger loop after the rescue");
        vm.prank(keeper);
        vm.expectRevert();
        vault.protect(address(0), address(0));

        // The same redemption now runs against the live testnet trove list.
        (uint256 collBefore,,,,,) = TM.getEntireDebtAndColl(address(vault));
        vm.prank(redeemer);
        TM.redeemCollateral(redeemAmt, address(0), address(0), address(0), 0, 0);
        assertLt(MUSD.balanceOf(redeemer), redeemAmt, "redemption happened");
        (uint256 collAfter,,,,,) = TM.getEntireDebtAndColl(address(vault));
        assertEq(collAfter, collBefore, "Alice's BTC untouched by the redemption");
    }

    /// @notice Other troves' redeemable debt (ICR >= 110% and below `icrLine`) in front of this vault.
    function _debtAheadOf(uint256 icrLine) internal view returns (uint256 acc) {
        address cur = ST.getLast();
        for (uint256 i; i < 80 && cur != address(0); i++) {
            if (cur != address(vault)) {
                uint256 cr = TM.getCurrentICR(cur, P0);
                if (cr >= 1.1e18) {
                    if (cr >= icrLine) break;
                    (, uint256 pr, uint256 it,, uint256 pp, uint256 pi) = TM.getEntireDebtAndColl(cur);
                    acc += pr + it + pp + pi;
                }
            }
            cur = ST.getPrev(cur);
        }
    }

    function test_RedemptionGuard_healthyWhenAlreadyBehind() public {
        _setRedemptionGuard(5_000e18); // vault is at ~228%: way behind the 114-131% troves at the front
        uint256 safe = vault.redemptionSafeICR(P0);
        assertGt(safe, 0);
        assertLt(safe, icr());
        vm.deal(address(vault), 0.05 ether);
        vm.prank(keeper);
        vm.expectRevert();
        vault.protect(address(0), address(0));
    }

    // helper: approve via low-level call (IERC20Min omits approve on purpose)
    function MUSDapprove(address, address spender, uint256 amt) internal {
        (bool ok,) = address(MUSD).call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        require(ok, "approve failed");
    }
}
