// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.22;

import { DynamicParam, DynamicParamLib } from "src/lib/DynamicParamLib.sol";
import { NTokenStrategy, IStrategy } from "src/NTokenStrategy.sol";
import { Pool } from "src/interfaces/IDFMM.sol";
import {
    decodeFeeUpdate,
    decodeWeightsUpdate,
    decodeControllerUpdate
} from "src/NTokenGeometricMean/NTokenGeometricMeanUtils.sol";
import {
    computeTradingFunction,
    computeDeltaGivenDeltaLRoundUp,
    computeDeltaGivenDeltaLRoundDown,
    computeSwapDeltaLiquidity
} from "src/NTokenGeometricMean/NTokenGeometricMeanMath.sol";
import { ONE, EPSILON } from "src/lib/StrategyLib.sol";

/**
 * @dev Parameterization of the GeometricMean curve.
 * @param weights Weights of the tokens in WAD.
 * @param swapFee Swap fee in WAD.
 * @param controller Address of the controller.
 */
struct NTokenGeometricMeanParams {
    uint256[] weights;
    uint256 swapFee;
    address controller;
}

enum UpdateCode {
    Invalid,
    SwapFee,
    Weights,
    Controller
}

/**
 * @notice N-Token Geometric Mean Market Maker.
 */
contract NTokenGeometricMean is NTokenStrategy {
    using DynamicParamLib for DynamicParam;

    struct InternalParams {
        DynamicParam[] weights;
        uint256 swapFee;
        address controller;
    }

    /// @inheritdoc IStrategy
    string public constant name = "NTokenGeometricMean";

    mapping(uint256 => InternalParams) public internalParams;

    /// @param dfmm_ Address of the DFMM contract.
    constructor(address dfmm_) NTokenStrategy(dfmm_) { }

    /// @dev Thrown when the sum of the weights is not equal to 1 (in WAD).
    error InvalidWeights(uint256 totalWeight);

    /// @dev Thrown when the length of the reserves and the tokens are not matching.
    error InvalidConfiguration(uint256 reservesLength, uint256 weightsLength);

    /// @dev Thrown when the length of the new weights does not match the old one.
    error InvalidWeightUpdateLength(uint256 updateLength, uint256 weightsLength);

    struct InitState {
        bool valid;
        int256 invariant;
        address controller;
        uint256 swapFee;
        uint256 totalLiquidity;
        uint256[] reserves;
        uint256[] weights;
    }

    /// @inheritdoc IStrategy
    function init(
        address,
        uint256 poolId,
        Pool calldata,
        bytes calldata data
    ) external onlyDFMM returns (bool, int256, uint256[] memory, uint256) {
        InitState memory state;

        (
            state.reserves,
            state.totalLiquidity,
            state.weights,
            state.swapFee,
            state.controller
        ) = abi.decode(data, (uint256[], uint256, uint256[], uint256, address));

        if (state.reserves.length != state.weights.length) {
            revert InvalidConfiguration(
                state.reserves.length, state.weights.length
            );
        }

        uint256 weightAccumulator;
        for (uint256 i = 0; i < state.weights.length; i++) {
            weightAccumulator += state.weights[i];
            internalParams[poolId].weights.push(
                DynamicParam({
                    lastComputedValue: state.weights[i],
                    updateEnd: 0,
                    updatePerSecond: 0,
                    lastUpdateAt: 0
                })
            );
        }

        if (weightAccumulator != ONE) {
            revert InvalidWeights(weightAccumulator);
        }

        internalParams[poolId].swapFee = state.swapFee;
        internalParams[poolId].controller = state.controller;

        int256 invariant = tradingFunction(
            state.reserves, state.totalLiquidity, getPoolParams(poolId)
        );

        bool valid = invariant >= 0 && invariant <= EPSILON;

        return (valid, invariant, state.reserves, state.totalLiquidity);
    }

    /// @inheritdoc IStrategy
    function update(
        address sender,
        uint256 poolId,
        Pool calldata,
        bytes calldata data
    ) external onlyDFMM {
        if (sender != internalParams[poolId].controller) revert InvalidSender();
        UpdateCode updateCode = abi.decode(data, (UpdateCode));

        if (updateCode == UpdateCode.SwapFee) {
            internalParams[poolId].swapFee = decodeFeeUpdate(data);
        } else if (updateCode == UpdateCode.Weights) {
            (uint256[] memory targetWeights, uint256 targetTimestamp) =
                decodeWeightsUpdate(data);
            if (targetWeights.length != internalParams[poolId].weights.length) {
                revert InvalidWeightUpdateLength(
                    targetWeights.length, internalParams[poolId].weights.length
                );
            }
            uint256 totalWeight;
            for (uint256 i = 0; i < targetWeights.length; i++) {
                totalWeight += targetWeights[i];
            }
            if (totalWeight != ONE) {
                revert InvalidWeights(totalWeight);
            }

            for (uint256 i = 0; i < targetWeights.length; i++) {
                internalParams[poolId].weights[i].set(
                    targetWeights[i], targetTimestamp
                );
            }
        } else if (updateCode == UpdateCode.Controller) {
            internalParams[poolId].controller = decodeControllerUpdate(data);
        } else {
            revert InvalidUpdateCode();
        }
    }

    /// @inheritdoc IStrategy
    function getPoolParams(uint256 poolId)
        public
        view
        override
        returns (bytes memory)
    {
        NTokenGeometricMeanParams memory params;

        params.weights = new uint256[](internalParams[poolId].weights.length);

        for (uint256 i = 0; i < params.weights.length; i++) {
            params.weights[i] = internalParams[poolId].weights[i].actualized();
        }

        params.swapFee = internalParams[poolId].swapFee;
        params.controller = internalParams[poolId].controller;

        return abi.encode(params);
    }

    /// @inheritdoc IStrategy
    function tradingFunction(
        uint256[] memory reserves,
        uint256 totalLiquidity,
        bytes memory params
    ) public pure override returns (int256) {
        return computeTradingFunction(
            reserves,
            totalLiquidity,
            abi.decode(params, (NTokenGeometricMeanParams))
        );
    }

    /// @inheritdoc NTokenStrategy
    function _computeAllocateDeltasAndReservesGivenDeltaL(
        uint256 deltaLiquidity,
        uint256[] memory maxDeltas,
        Pool memory pool
    )
        internal
        pure
        override
        returns (uint256[] memory deltas, uint256[] memory nextReserves)
    {
        deltas = new uint256[](pool.reserves.length);
        nextReserves = new uint256[](pool.reserves.length);
        for (uint256 i = 0; i < pool.reserves.length; i++) {
            uint256 reserveT = pool.reserves[i];
            deltas[i] = computeDeltaGivenDeltaLRoundUp(
                pool.reserves[i], deltaLiquidity, pool.totalLiquidity
            );
            if (deltas[i] > maxDeltas[i]) {
                revert DeltaError(maxDeltas[i], deltas[i]);
            }
            nextReserves[i] = reserveT + deltas[i];
        }
    }

    /// @inheritdoc NTokenStrategy
    function _computeDeallocateDeltasAndReservesGivenDeltaL(
        uint256 deltaLiquidity,
        uint256[] memory minDeltas,
        Pool memory pool
    )
        internal
        pure
        override
        returns (uint256[] memory deltas, uint256[] memory nextReserves)
    {
        deltas = new uint256[](pool.reserves.length);
        nextReserves = new uint256[](pool.reserves.length);
        for (uint256 i = 0; i < pool.reserves.length; i++) {
            uint256 reserveT = pool.reserves[i];
            deltas[i] = computeDeltaGivenDeltaLRoundDown(
                reserveT, deltaLiquidity, pool.totalLiquidity
            );
            if (minDeltas[i] > deltas[i]) {
                revert DeltaError(minDeltas[i], deltas[i]);
            }
            nextReserves[i] = reserveT - deltas[i];
        }
    }

    /// @inheritdoc NTokenStrategy
    function _computeSwapDeltaLiquidity(
        Pool memory pool,
        bytes memory params,
        uint256 tokenInIndex,
        uint256,
        uint256 amountIn,
        uint256
    ) internal pure override returns (uint256) {
        NTokenGeometricMeanParams memory poolParams =
            abi.decode(params, (NTokenGeometricMeanParams));

        return computeSwapDeltaLiquidity(
            amountIn,
            pool.reserves[tokenInIndex],
            pool.totalLiquidity,
            poolParams.weights[tokenInIndex],
            poolParams.swapFee
        );
    }
}
