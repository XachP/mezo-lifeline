// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LifelineFactory} from "../src/LifelineFactory.sol";
import {IBorrowerOperations, ITroveManager, IPriceFeed, IERC20Min, ISortedTroves} from "../src/interfaces/IMezo.sol";

/// forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast --private-key $DEPLOYER_KEY
contract Deploy is Script {
    // Mezo testnet (matsnet). Mainnet addresses live in mezo-org/musd/solidity/deployments/mainnet.
    address constant BO = 0xCdF7028ceAB81fA0C6971208e83fa7872994beE5;
    address constant TM = 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0;
    address constant PF = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address constant ST = 0x722E4D24FD6Ff8b0AC679450F3D91294607268fA;

    function run() external returns (LifelineFactory f) {
        vm.startBroadcast();
        f = new LifelineFactory(IBorrowerOperations(BO), ITroveManager(TM), IPriceFeed(PF), IERC20Min(MUSD), ISortedTroves(ST));
        vm.stopBroadcast();
        console.log("LifelineFactory:", address(f));
    }
}
