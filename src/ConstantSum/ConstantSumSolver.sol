// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "./ConstantSum.sol";
import "src/interfaces/IStrategy.sol";
import { IDFMM } from "src/interfaces/IDFMM.sol";
import "solmate/tokens/ERC20.sol";

contract ConstantSumSolver {
    error NotEnoughLiquidity();

    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    struct Reserves {
        uint256 rx;
        uint256 ry;
        uint256 L;
    }

    address public strategy;

    constructor(address strategy_) {
        strategy = strategy_;
    }

    function getInitialPoolData(
        uint256 rx,
        uint256 ry,
        ConstantSumParams memory params
    ) public pure returns (bytes memory) {
        return computeInitialPoolData(rx, ry, params);
    }

    struct SimulateSwapState {
        uint256 amountOut;
        uint256 deltaLiquidity;
    }

    function simulateSwap(
        uint256 poolId,
        bool swapXIn,
        uint256 amountIn
    ) public view returns (bool, uint256, bytes memory) {
        (uint256[] memory reserves, uint256 totalLiquidity) =
            IDFMM(IStrategy(strategy).dfmm()).getReservesAndLiquidity(poolId);
        ConstantSumParams memory poolParams = abi.decode(
            IStrategy(strategy).getPoolParams(poolId), (ConstantSumParams)
        );

        SimulateSwapState memory state;

        if (swapXIn) {
            state.deltaLiquidity = amountIn.mulWadUp(poolParams.swapFee);
            state.amountOut = amountIn.mulWadDown(poolParams.price).mulWadDown(
                ONE - poolParams.swapFee
            );

            if (reserves[1] < state.amountOut) {
                revert NotEnoughLiquidity();
            }
        } else {
            state.deltaLiquidity =
                amountIn.mulWadUp(poolParams.swapFee).divWadUp(poolParams.price);
            state.amountOut = (ONE - poolParams.swapFee).mulWadDown(amountIn)
                .divWadDown(poolParams.price);

            if (reserves[0] < state.amountOut) {
                revert NotEnoughLiquidity();
            }
        }

        bytes memory swapData;

        if (swapXIn) {
            swapData = abi.encode(
                0, 1, amountIn, state.amountOut, state.deltaLiquidity
            );
        } else {
            swapData = abi.encode(
                1, 0, amountIn, state.amountOut, state.deltaLiquidity
            );
        }

        Pool memory pool;
        pool.reserves = reserves;
        pool.totalLiquidity = totalLiquidity;

        (bool valid,,,,,,) = IStrategy(strategy).validateSwap(
            address(this), poolId, pool, swapData
        );
        return (valid, state.amountOut, swapData);
    }

    function preparePriceUpdate(uint256 newPrice)
        public
        pure
        returns (bytes memory)
    {
        return encodePriceUpdate(newPrice, 0);
    }
}