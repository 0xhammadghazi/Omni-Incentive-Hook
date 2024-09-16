// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OmniIncentiveHook} from "../src/OmniIncentiveHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionConfig} from "v4-periphery/src/libraries/PositionConfig.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniIncentiveHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    OmniIncentiveHook hook;
    PoolId poolId;

    uint256 tokenId;
    PositionConfig config;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG) ^
                (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(
            manager,
            "OmniIncentiveHook",
            "OIH"
        ); //Add all the necessary constructor arguments from the hook
        deployCodeTo(
            "OmniIncentiveHook.sol:OmniIncentiveHook",
            constructorArgs,
            flags
        );
        hook = OmniIncentiveHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide full-range liquidity to the pool
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        (tokenId, ) = posm.mint(
            config,
            10_000e18,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            address(this),
            block.timestamp,
            getHookData(msg.sender)
        );
    }

    function testSwapHooks() public {
        // positions were created in setup()

        // Preparing hook data
        bytes memory hookData = getHookData(msg.sender);

        OmniIncentiveHook.Bond memory bond = OmniIncentiveHook.Bond({
            bondMarketOwner: address(0),
            rewardToken: IERC20(Currency.unwrap(key.currency1)),
            isRewardTokenCurrency0: false,
            rewardTokensToDistribute: 1000 ether,
            rewardPercentage: 500, // 5%
            campaignStartTime: 0,
            campaignEndTime: 3 days,
            campaignCliffTime: 2 days,
            campaignVestingDuration: 6 days,
            rewardTokensDistributed: 0
        });

        bond.rewardToken.approve(address(hook), type(uint256).max);

        // Creating Campaign
        hook.createCampaign(key, OmniIncentiveHook.BondType.Swap, bond);

        // Perform a test swap
        bool zeroForOne = true;
        int256 amountSpecified = 12e18;
        BalanceDelta swapDelta = swap(
            key,
            zeroForOne,
            amountSpecified,
            hookData
        );

        // Correct swap amount assertion
        assertEq(int256(swapDelta.amount1()), amountSpecified);

        // ERC-5725 mint assertion
        assertEq(hook.balanceOf(msg.sender), 1);

        // Rewards payout assertions at different times
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 2e17);

        vm.warp(block.timestamp + 2 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 4e17);

        vm.warp(block.timestamp + 2 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 6e17);

        // Claiming rewards

        uint256 beforeBalance = bond.rewardToken.balanceOf(msg.sender);
        vm.prank(msg.sender);
        hook.claim(0);
        assertEq(
            beforeBalance + hook.vestedPayoutAtTime(0, block.timestamp),
            bond.rewardToken.balanceOf(msg.sender)
        );
    }

    function testLiquidityHooks() public {
        // positions were created in setup()

        OmniIncentiveHook.Bond memory bond = OmniIncentiveHook.Bond({
            bondMarketOwner: address(0),
            rewardToken: IERC20(Currency.unwrap(key.currency1)),
            isRewardTokenCurrency0: false,
            rewardTokensToDistribute: 1000 ether,
            rewardPercentage: 500, // 5%
            campaignStartTime: 0,
            campaignEndTime: 3 days,
            campaignCliffTime: 2 days,
            campaignVestingDuration: 6 days,
            rewardTokensDistributed: 0
        });

        bond.rewardToken.approve(address(hook), type(uint256).max);

        // Creating Campaign
        hook.createCampaign(key, OmniIncentiveHook.BondType.Liquidity, bond);

        uint256 liquidityToAdd = 12e18;

        BalanceDelta liqudiityDelta = posm.increaseLiquidity(
            tokenId,
            config,
            liquidityToAdd,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            MAX_SLIPPAGE_ADD_LIQUIDITY,
            block.timestamp,
            getHookData(msg.sender)
        );

        // Liquidity deposited assertion
        assertEq(uint256(int256(-liqudiityDelta.amount1())), 12e18);

        // ERC-5725 mint assertion
        assertEq(hook.balanceOf(msg.sender), 1);

        // Rewards payout assertions at different times
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 0);

        vm.warp(block.timestamp + 1 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 2e17);

        vm.warp(block.timestamp + 2 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 4e17);

        vm.warp(block.timestamp + 2 days);
        assertEq(hook.vestedPayoutAtTime(0, block.timestamp), 6e17);

        // Claiming rewards

        uint256 beforeBalance = bond.rewardToken.balanceOf(msg.sender);
        vm.prank(msg.sender);
        hook.claim(0);
        assertEq(
            beforeBalance + hook.vestedPayoutAtTime(0, block.timestamp),
            bond.rewardToken.balanceOf(msg.sender)
        );
    }

    function getHookData(address caller) public pure returns (bytes memory) {
        return abi.encode(caller);
    }
}
