// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LifelineFactory} from "../src/LifelineFactory.sol";
import {ExternalKeeper} from "../src/ExternalKeeper.sol";
import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves, IMUSDSavings} from "../src/interfaces/IMezo.sol";

/// @notice Fresh Mezo testnet deploy of LifelineFactory and ExternalKeeper.
///         Prints the `docs/config.js` fields. Does not write that file and does not
///         open a demo vault.
///
///         forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast --private-key $DEPLOYER_KEY
///
///         Optional environment (Forge loads `.env`, which is gitignored — do not commit it or a key):
///         - MUSD_SAVINGS: savings vault the factory passes to each LifelineVault.
///           Defaults to the live matsnet MUSD Savings Rate. The script checks `musdToken()`.
///         - KEEPER_OPERATOR: address that can withdraw ExternalKeeper tips. Defaults to the broadcaster.
///         - DEMO_VAULT: included in the printed config only when set. This script does not create one.
contract Deploy is Script {
    // Mezo testnet (matsnet). Mainnet musd addresses live in mezo-org/musd/solidity/deployments/mainnet.
    address constant BO = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TM = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant PF = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant ST = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;
    address constant HINTS = 0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6;
    /// @dev Live matsnet MUSD Savings Rate. `musdToken()` is matsnet MUSD. Not a market for sMUSD.
    address constant DEFAULT_SAVINGS = 0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16;

    function run() external returns (LifelineFactory f, ExternalKeeper keeper) {
        address savingsAddr = vm.envOr("MUSD_SAVINGS", DEFAULT_SAVINGS);
        address operator = vm.envOr("KEEPER_OPERATOR", msg.sender);
        address demo = vm.envOr("DEMO_VAULT", address(0));
        if (IMUSDSavings(savingsAddr).musdToken() != MUSD) revert("MUSD_SAVINGS.musdToken is not matsnet MUSD");

        vm.startBroadcast();
        f = new LifelineFactory(
            IBorrowerOperations(BO), ITroveManager(TM), IPriceFeed(PF), IERC20Min(MUSD), ISortedTroves(ST), IMUSDSavings(savingsAddr)
        );
        keeper = new ExternalKeeper(operator);
        vm.stopBroadcast();

        console.log("LifelineFactory:", address(f));
        console.log("ExternalKeeper:", address(keeper));
        console.log("savings:", savingsAddr);
        _printConfig(address(f), address(keeper), savingsAddr, demo);
    }

    function _printConfig(address factory, address keeper, address savingsAddr, address demo) internal pure {
        string memory demoLine = demo == address(0)
            ? '  demoVault: "", // DEMO_VAULT unset. This script does not create a demo vault.'
            : string.concat('  demoVault: "', vm.toString(demo), '",');
        console.log("----- docs/config.js (paste after an explicit broadcast; this script does not write the file) -----");
        console.log("window.GUARDIAN_CONFIG = {");
        console.log("  chainId: 31611,");
        console.log('  chainName: "Mezo Testnet",');
        console.log('  rpcUrl: "https://rpc.test.mezo.org",');
        console.log('  explorer: "https://explorer.test.mezo.org",');
        console.log(string.concat('  factory: "', vm.toString(factory), '",'));
        console.log(string.concat('  externalKeeper: "', vm.toString(keeper), '",'));
        console.log(demoLine);
        console.log(string.concat('  savingsVault: "', vm.toString(savingsAddr), '",'));
        console.log(string.concat('  musd: "', vm.toString(MUSD), '",'));
        console.log(string.concat('  priceFeed: "', vm.toString(PF), '",'));
        console.log(string.concat('  troveManager: "', vm.toString(TM), '",'));
        console.log(string.concat('  sortedTroves: "', vm.toString(ST), '",'));
        console.log(string.concat('  hintHelpers: "', vm.toString(HINTS), '",'));
        console.log("};");
    }
}
