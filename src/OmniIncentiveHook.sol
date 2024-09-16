// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC5725} from "./interfaces/IERC5725.sol";

import "forge-std/console.sol";

contract OmniIncentiveHook is BaseHook, IERC5725, ERC721 {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    enum BondType {
        Liquidity,
        Swap
    }

    struct Bond {
        address bondMarketOwner; // market owner, sends payout tokens. zero address = msg.sender
        IERC20 rewardToken;
        bool isRewardTokenCurrency0;
        uint256 rewardTokensToDistribute;
        uint256 rewardPercentage; // Percentage of tokens awarded as a reward for buying or providing liquidity.
        uint256 rewardTokensDistributed;
        uint256 campaignStartTime; // 0 = block.timestamp
        uint256 campaignCliffTime;
        uint256 campaignEndTime;
        uint256 campaignVestingDuration; // Duration after which all rewards will be fully vested.
    }

    struct VestDetails {
        PoolId poolId;
        IERC20 rewardToken;
        uint256 totalAllocatedRewards;
        uint256 rewardsClaimed;
        uint256 vestingStart; // When vesting starts
        uint256 vestingEnd; // When vesting end
        uint256 vestingCliff; // Duration after which tokens will be begin releasing
    }

    // Tracker of current NFT id
    uint256 public tokenIdTracker;

    mapping(PoolId => mapping(BondType => Bond)) public bondMarkets;

    mapping(uint256 => VestDetails) public vestDetails;

    // ERC5725 related state variables

    // From token ID to approved tokenId operator
    mapping(uint256 => address) private _tokenIdApprovals;

    // From owner to operator approvals
    mapping(address => mapping(address => bool)) /* owner */ /*(operator, isApproved)*/
        internal _operatorApprovals;

    event BondMarketCreated(
        PoolId indexed poolId,
        BondType bondType,
        IERC20 rewardToken,
        uint256 campaignStartTime
    );

    event SwapBondIssued(
        PoolId indexed poolId,
        address bondRecipient,
        uint256 tokenId,
        uint256 reward
    );

    event LiquidityBondIssued(
        PoolId indexed poolId,
        address bondRecipient,
        uint256 tokenId,
        uint256 reward
    );

    error InvalidCampaignParams();

    constructor(
        IPoolManager _poolManager,
        string memory _name,
        string memory _symbol
    ) BaseHook(_poolManager) ERC721(_name, _symbol) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function createCampaign(
        PoolKey calldata key,
        BondType bondType,
        Bond memory bond
    ) external onlyValidPools(key.hooks) returns (PoolId) {
        bond.campaignStartTime = bond.campaignStartTime == 0
            ? block.timestamp
            : bond.campaignStartTime;

        // Start time must be in the future and less than end time, cliff period should be less than vesting duration
        if (
            bond.campaignStartTime < block.timestamp ||
            bond.campaignStartTime >= bond.campaignEndTime ||
            bond.campaignCliffTime > bond.campaignVestingDuration
        ) revert InvalidCampaignParams();

        if (
            bond.rewardTokensToDistribute == 0 ||
            bond.rewardPercentage == 0 ||
            bond.rewardPercentage > 10000
        ) revert InvalidCampaignParams();

        // setting bond owner
        bond.bondMarketOwner = bond.bondMarketOwner == address(0)
            ? msg.sender
            : bond.bondMarketOwner;

        // setting reward token address
        bond.rewardToken = IERC20(
            bond.isRewardTokenCurrency0
                ? Currency.unwrap(key.currency0)
                : Currency.unwrap(key.currency1)
        );

        bondMarkets[key.toId()][bondType] = Bond({
            bondMarketOwner: bond.bondMarketOwner,
            rewardToken: bond.rewardToken,
            isRewardTokenCurrency0: bond.isRewardTokenCurrency0,
            rewardTokensToDistribute: bond.rewardTokensToDistribute,
            rewardPercentage: bond.rewardPercentage,
            rewardTokensDistributed: 0,
            campaignStartTime: bond.campaignStartTime,
            campaignCliffTime: bond.campaignCliffTime,
            campaignEndTime: bond.campaignEndTime,
            campaignVestingDuration: bond.campaignVestingDuration
        });

        bond.rewardToken.safeTransferFrom(
            bond.bondMarketOwner,
            address(this),
            bond.rewardTokensToDistribute
        );

        emit BondMarketCreated(
            key.toId(),
            bondType,
            bond.rewardToken,
            bond.campaignStartTime
        );

        return key.toId();
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, int128) {
        Bond storage swapBond = bondMarkets[key.toId()][BondType.Swap];
        // Proceed if campaign exist, has started, isn't ended, and isn't sold out
        if (
            block.timestamp >= swapBond.campaignStartTime &&
            block.timestamp <= swapBond.campaignEndTime &&
            swapBond.rewardTokensDistributed !=
            swapBond.rewardTokensToDistribute
        ) {
            // Proceed if user is buying project's token
            if (swapBond.isRewardTokenCurrency0 != swapParams.zeroForOne) {
                uint256 tokensBought = swapBond.isRewardTokenCurrency0
                    ? uint256(int256(delta.amount0()))
                    : uint256(int256(delta.amount1()));

                uint256 reward = (tokensBought * swapBond.rewardPercentage) /
                    10000;

                reward = _min(
                    reward,
                    swapBond.rewardTokensToDistribute -
                        swapBond.rewardTokensDistributed
                );

                swapBond.rewardTokensDistributed += reward;

                uint256 newTokenId = tokenIdTracker;

                vestDetails[newTokenId] = VestDetails({
                    poolId: key.toId(),
                    rewardToken: IERC20(swapBond.rewardToken),
                    rewardsClaimed: 0,
                    totalAllocatedRewards: reward,
                    vestingStart: block.timestamp,
                    vestingEnd: block.timestamp +
                        swapBond.campaignVestingDuration,
                    vestingCliff: block.timestamp + swapBond.campaignCliffTime
                });

                tokenIdTracker++;

                address trader = abi.decode(hookData, (address));
                _mint(trader, newTokenId);

                emit SwapBondIssued(key.toId(), trader, newTokenId, reward);
            }
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyByPoolManager returns (bytes4, BalanceDelta) {
        Bond storage liquidityBond = bondMarkets[key.toId()][
            BondType.Liquidity
        ];

        // Proceed if campaign exist, has started, isn't ended, and isn't sold out
        if (
            block.timestamp >= liquidityBond.campaignStartTime &&
            block.timestamp <= liquidityBond.campaignEndTime &&
            liquidityBond.rewardTokensDistributed !=
            liquidityBond.rewardTokensToDistribute
        ) {
            uint256 depositedProjectTokens = liquidityBond
                .isRewardTokenCurrency0
                ? uint256(int256(-delta.amount0()))
                : uint256(int256(-delta.amount1()));

            uint256 reward = (depositedProjectTokens *
                liquidityBond.rewardPercentage) / 10000;

            reward = _min(
                reward,
                liquidityBond.rewardTokensToDistribute -
                    liquidityBond.rewardTokensDistributed
            );

            liquidityBond.rewardTokensDistributed += reward;

            uint256 newTokenId = tokenIdTracker;

            vestDetails[newTokenId] = VestDetails({
                poolId: key.toId(),
                rewardToken: IERC20(liquidityBond.rewardToken),
                rewardsClaimed: 0,
                totalAllocatedRewards: reward,
                vestingStart: block.timestamp,
                vestingEnd: block.timestamp +
                    liquidityBond.campaignVestingDuration,
                vestingCliff: block.timestamp + liquidityBond.campaignCliffTime
            });

            tokenIdTracker++;

            address liquidityProvider = abi.decode(hookData, (address));
            _mint(liquidityProvider, newTokenId);

            emit LiquidityBondIssued(
                key.toId(),
                liquidityProvider,
                newTokenId,
                reward
            );
        }
        return (this.afterAddLiquidity.selector, delta);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }

    // ERC5725 Related Functions

    modifier validToken(uint256 tokenId) {
        require(_ownerOf(tokenId) != address(0), "ERC5725: invalid token ID");
        _;
    }

    // To claim rewards
    function claim(
        uint256 tokenId
    ) external override(IERC5725) validToken(tokenId) {
        require(
            isApprovedClaimOrOwner(msg.sender, tokenId),
            "ERC5725: not owner or operator"
        );

        uint256 amountClaimed = claimablePayout(tokenId);
        require(amountClaimed > 0, "ERC5725: No pending payout");

        emit PayoutClaimed(tokenId, msg.sender, amountClaimed);

        // Adjust payout values
        vestDetails[tokenId].rewardsClaimed += amountClaimed;
        IERC20(payoutToken(tokenId)).safeTransfer(msg.sender, amountClaimed);
    }

    /**
     * @dev See {IERC5725}.
     */
    function vestedPayoutAtTime(
        uint256 tokenId,
        uint256 timestamp
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (uint256 payout)
    {
        if (timestamp < _cliff(tokenId)) {
            return 0;
        }
        if (timestamp >= _endTime(tokenId)) {
            return _payout(tokenId);
        }

        uint256 timeElapsed = block.timestamp - _startTime(tokenId);
        uint256 vestingDuration = _endTime(tokenId) - _startTime(tokenId);
        return (_payout(tokenId) * timeElapsed) / vestingDuration;
    }

    /**
     * @dev See {IERC5725}.
     */
    function setClaimApprovalForAll(
        address operator,
        bool approved
    ) external override(IERC5725) {
        _setClaimApprovalForAll(operator, approved);
        emit ClaimApprovalForAll(msg.sender, operator, approved);
    }

    /**
     * @dev See {IERC5725}.
     */
    function setClaimApproval(
        address operator,
        bool approved,
        uint256 tokenId
    ) external override(IERC5725) validToken(tokenId) {
        _setClaimApproval(operator, tokenId);
        emit ClaimApproval(msg.sender, operator, tokenId, approved);
    }

    /**
     * @dev See {IERC5725}.
     */
    function vestedPayout(
        uint256 tokenId
    ) public view override(IERC5725) returns (uint256 payout) {
        return vestedPayoutAtTime(tokenId, block.timestamp);
    }

    /**
     * @dev See {IERC5725}.
     */
    function vestingPayout(
        uint256 tokenId
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (uint256 payout)
    {
        return _payout(tokenId) - vestedPayout(tokenId);
    }

    /**
     * @dev See {IERC5725}.
     */
    function claimablePayout(
        uint256 tokenId
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (uint256 payout)
    {
        return vestedPayout(tokenId) - vestDetails[tokenId].rewardsClaimed;
    }

    /**
     * @dev See {IERC5725}.
     */
    function claimedPayout(
        uint256 tokenId
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (uint256 payout)
    {
        return vestDetails[tokenId].rewardsClaimed;
    }

    /**
     * @dev See {IERC5725}.
     */
    function vestingPeriod(
        uint256 tokenId
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (uint256 vestingStart, uint256 vestingEnd)
    {
        return (_startTime(tokenId), _endTime(tokenId));
    }

    /**
     * @dev See {IERC5725}.
     */
    function payoutToken(
        uint256 tokenId
    )
        public
        view
        override(IERC5725)
        validToken(tokenId)
        returns (address token)
    {
        return address(vestDetails[tokenId].rewardToken);
    }

    /**
     * @dev See {IERC5725}.
     */
    function getClaimApproved(
        uint256 tokenId
    ) public view returns (address operator) {
        return _tokenIdApprovals[tokenId];
    }

    /**
     * @dev Returns true if `owner` has set `operator` to manage all `tokenId`s.
     * @param owner The owner allowing `operator` to manage all `tokenId`s.
     * @param operator The address who is given permission to spend tokens on behalf of the `owner`.
     */
    function isClaimApprovedForAll(
        address owner,
        address operator
    ) public view returns (bool isClaimApproved) {
        return _operatorApprovals[owner][operator];
    }

    /**
     * @dev Public view which returns true if the operator has permission to claim for `tokenId`
     * @notice To remove permissions, set operator to zero address.
     *
     * @param operator The address that has permission for a `tokenId`.
     * @param tokenId The NFT `tokenId`.
     */
    function isApprovedClaimOrOwner(
        address operator,
        uint256 tokenId
    ) public view virtual returns (bool) {
        address owner = ownerOf(tokenId);
        return (operator == owner ||
            isClaimApprovedForAll(owner, operator) ||
            getClaimApproved(tokenId) == operator);
    }

    /**
     * @dev Internal function to set the operator status for a given owner to manage all `tokenId`s.
     * @notice To remove permissions, set approved to false.
     *
     * @param operator The address who is given permission to spend vested tokens.
     * @param approved The approved status.
     */
    function _setClaimApprovalForAll(
        address operator,
        bool approved
    ) internal virtual {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    /**
     * @dev Internal function to set the operator status for a given tokenId.
     * @notice To remove permissions, set operator to zero address.
     *
     * @param operator The address who is given permission to spend vested tokens.
     * @param tokenId The NFT `tokenId`.
     */
    function _setClaimApproval(
        address operator,
        uint256 tokenId
    ) internal virtual {
        require(
            ownerOf(tokenId) == msg.sender,
            "ERC5725: not owner of tokenId"
        );
        _tokenIdApprovals[tokenId] = operator;
    }

    /**
     * @dev See {ERC5725}.
     */
    function _payout(uint256 tokenId) internal view returns (uint256) {
        return vestDetails[tokenId].totalAllocatedRewards;
    }

    /**
     * @dev See {ERC5725}.
     */
    function _startTime(uint256 tokenId) internal view returns (uint256) {
        return vestDetails[tokenId].vestingStart;
    }

    /**
     * @dev See {ERC5725}.
     */
    function _endTime(uint256 tokenId) internal view returns (uint256) {
        return vestDetails[tokenId].vestingEnd;
    }

    /**
     * @dev Internal function to get the cliff time of a given linear vesting NFT
     *
     * @param tokenId to check
     * @return uint256 the cliff time in seconds
     */
    function _cliff(uint256 tokenId) internal view returns (uint256) {
        return vestDetails[tokenId].vestingCliff;
    }
}
