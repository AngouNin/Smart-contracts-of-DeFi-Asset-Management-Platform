// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../../chains/PolygonLib.sol";
import "../ChainSetup.sol";
import "../../../src/core/Platform.sol";
import "../../../src/core/Factory.sol";

abstract contract PolygonSetup is ChainSetup {
    bool public showDeployLog;

    constructor() {
        vm.selectFork(vm.createFork(vm.envString("POLYGON_RPC_URL")));
        // vm.rollFork(48098000); // Sep-01-2023 03:23:25 PM +UTC
        // vm.rollFork(51800000); // Jan-01-2024 02:33:32 AM +UTC
        // vm.rollFork(54000000); // Feb-27-2024 12:56:05 AM +UTC
        vm.rollFork(55000000); // Mar-23-2024 07:56:52 PM +UTC
    }

    function testPolygonSetupStub() external {}

    function _init() internal override {
        //region ----- DeployPlatform -----
        platform = Platform(PolygonLib.runDeploy(showDeployLog));
        factory = Factory(address(platform.factory()));
        //endregion -- DeployPlatform ----
    }

    function _deal(address token, address to, uint amount) internal override {
        if (token == PolygonLib.TOKEN_USDC) {
            vm.prank(0xe7804c37c13166fF0b37F5aE0BB07A3aEbb6e245); // 0xe7804c37c13166fF0b37F5aE0BB07A3aEbb6e245
            IERC20(token).transfer(to, amount);
        } else {
            deal(token, to, amount);
        }
    }
}
