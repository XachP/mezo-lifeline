// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LifelineVault} from "../src/LifelineVault.sol";
import {LifelineFactory} from "../src/LifelineFactory.sol";
import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves} from "../src/interfaces/IMezo.sol";

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

    uint256 constant P0 = 84_000e18; // starting BTC price
    LifelineFactory factory;
    LifelineVault vault;
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address mallory = makeAddr("mallory");

    function setUp() public {
        vm.createSelectFork("mezo_testnet");
        setPrice(P0);
        factory = new LifelineFactory(BO, TM, PF, MUSD, ST);
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

    function test_Protect_recoveryModeRaisesTheBar() public {
        vm.prank(alice);
        vault.fundReserve{value: 0.05 ether}(0);
        // System TCR on testnet is ~300%; a 55% crash pushes the whole system into Recovery Mode (<150%).
        setPrice((P0 * 45) / 100);
        assertTrue(TM.checkRecoveryMode(PF.fetchPrice()), "system in recovery mode");
        (uint256 trig, uint256 tgt) = vault.effectiveThresholds(true);
        assertEq(trig, 1.55e18);
        assertEq(tgt, 1.65e18);

        vm.prank(keeper);
        vault.protect(address(0), address(0));
        assertGe(icr(), 1.649e18, "lifted above the RM danger line");
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
        // Alice's vault sits at ~127% ICR: far from liquidation (trigger 120%), but it's near the FRONT of
        // the real testnet redemption queue, where redemptions take BTC from the lowest-ICR troves >= 110%.
        vm.startPrank(alice);
        vault.withdrawColl(0.06 ether - 0.0334 ether, address(0), address(0));
        vault.fundReserve{value: 0.05 ether}(0);
        vm.stopPrank();
        uint256 before = icr();
        assertLt(before, 1.3e18);
        assertGt(before, 1.2e18);

        // Control: WITHOUT the guard, the same 20,000 MUSD redemption takes some of Alice's BTC.
        address redeemer = makeAddr("redeemer");
        deal(address(MUSD), redeemer, 20_000e18);
        uint256 snap = vm.snapshotState();
        (uint256 c0,,,,,) = TM.getEntireDebtAndColl(address(vault));
        vm.prank(redeemer);
        TM.redeemCollateral(20_000e18, address(0), address(0), address(0), 0, 0);
        (uint256 c1,,,,,) = TM.getEntireDebtAndColl(address(vault));
        assertLt(c1, c0, "control: unguarded, Alice gets redeemed");
        vm.revertToState(snap);

        _setRedemptionGuard(25_000e18); // keep >= 25,000 MUSD of other troves' debt in front of me
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

        // A real 20,000 MUSD redemption now runs against the live testnet trove list.
        (uint256 collBefore,,,,,) = TM.getEntireDebtAndColl(address(vault));
        vm.prank(redeemer);
        TM.redeemCollateral(20_000e18, address(0), address(0), address(0), 0, 0);
        assertLt(MUSD.balanceOf(redeemer), 20_000e18, "redemption happened");
        (uint256 collAfter,,,,,) = TM.getEntireDebtAndColl(address(vault));
        assertEq(collAfter, collBefore, "Alice's BTC untouched by the redemption");
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
