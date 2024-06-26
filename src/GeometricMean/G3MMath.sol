// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { GeometricMeanParams } from "src/GeometricMean/GeometricMean.sol";
import { bisection } from "src/lib/BisectionLib.sol";
import { ONE } from "src/lib/StrategyLib.sol";

using FixedPointMathLib for uint256;
using FixedPointMathLib for int256;

function computeTradingFunction(
    uint256 rX,
    uint256 rY,
    uint256 L,
    GeometricMeanParams memory params
) pure returns (int256) {
    uint256 a = uint256(int256(rX.divWadUp(L)).powWad(int256(params.wX)));
    uint256 b = uint256(int256(rY.divWadUp(L)).powWad(int256(params.wY)));

    return int256(a.mulWadUp(b)) - int256(1 ether);
}

function computeDeltaGivenDeltaLRoundUp(
    uint256 reserve,
    uint256 deltaLiquidity,
    uint256 totalLiquidity
) pure returns (uint256) {
    return reserve.mulDivUp(deltaLiquidity, totalLiquidity);
}

function computeDeltaGivenDeltaLRoundDown(
    uint256 reserve,
    uint256 deltaLiquidity,
    uint256 totalLiquidity
) pure returns (uint256) {
    return reserve.mulDivDown(deltaLiquidity, totalLiquidity);
}

function computeLGivenX(
    uint256 x,
    uint256 S,
    GeometricMeanParams memory params
) pure returns (uint256) {
    int256 a = int256(params.wY.mulDivUp(S, params.wX));
    int256 b = a.powWad(int256(params.wY));
    return x.mulWadUp(uint256(b));
}

function computeAllocationGivenDeltaX(
    uint256 deltaX,
    uint256 rX,
    uint256 rY,
    uint256 totalLiquidity
) pure returns (uint256 deltaY, uint256 deltaL) {
    uint256 a = deltaX.divWadUp(rX);
    deltaY = a.mulWadUp(rY);
    deltaL = a.mulWadUp(totalLiquidity);
}

function computeAllocationGivenDeltaY(
    uint256 deltaY,
    uint256 rX,
    uint256 rY,
    uint256 totalLiquidity
) pure returns (uint256 deltaX, uint256 deltaL) {
    uint256 a = deltaY.divWadUp(rY);
    deltaX = a.mulWadUp(rX);
    deltaL = a.mulWadUp(totalLiquidity);
}

function computeDeallocationGivenDeltaX(
    uint256 deltaX,
    uint256 rX,
    uint256 rY,
    uint256 totalLiquidity
) pure returns (uint256 deltaY, uint256 deltaL) {
    uint256 a = deltaX.divWadDown(rX);
    deltaY = a.mulWadDown(rY);
    deltaL = a.mulWadDown(totalLiquidity);
}

function computeDeallocationGivenDeltaY(
    uint256 deltaY,
    uint256 rX,
    uint256 rY,
    uint256 totalLiquidity
) pure returns (uint256 deltaX, uint256 deltaL) {
    uint256 a = deltaY.divWadDown(rY);
    deltaX = a.mulWadDown(rX);
    deltaL = a.mulWadDown(totalLiquidity);
}

function computeY(
    uint256 x,
    uint256 S,
    GeometricMeanParams memory params
) pure returns (uint256) {
    return params.wY.divWadDown(params.wX).mulWadDown(S).mulWadDown(x);
}

function computeL(
    uint256 x,
    uint256 y,
    GeometricMeanParams memory params
) pure returns (uint256) {
    uint256 a = uint256(int256(x).powWad(int256(params.wX)));
    uint256 b = uint256(int256(y).powWad(int256(params.wY)));

    return a.mulWadUp(b);
}

/// @dev Finds the root of the swapConstant given the independent variable rX.
function computeNextRy(
    uint256 rX,
    uint256 liquidity,
    GeometricMeanParams memory params
) pure returns (uint256 rY) {
    rY = uint256(
        int256(
            liquidity.divWadUp(uint256(int256(rX).powWad(int256(params.wX))))
        ).powWad(int256(ONE.divWadUp(params.wY)))
    );
}

/// @dev Finds the root of the swapConstant given the independent variable rY.
function computeNextRx(
    uint256 rY,
    uint256 liquidity,
    GeometricMeanParams memory params
) pure returns (uint256 rX) {
    rX = uint256(
        int256(
            liquidity.divWadUp(uint256(int256(rY).powWad(int256(params.wY))))
        ).powWad(int256(ONE.divWadUp(params.wX)))
    );
}

/// @dev Computes the approximated spot price given current reserves and liquidity.
function computePrice(
    uint256 rX,
    uint256 rY,
    GeometricMeanParams memory params
) pure returns (uint256 price) {
    uint256 n = rY.divWadDown(params.wY);
    uint256 d = rX.divWadDown(params.wX);
    price = n.divWadDown(d);
}

/// @dev This is a pure anonymous function defined at the file level, which allows
/// it to be passed as an argument to another function. BisectionLib.sol takes this
/// function as an argument to find the root of the trading function given the liquidity.
function findRootLiquidity(
    bytes memory data,
    uint256 L
) pure returns (int256) {
    (uint256 rX, uint256 rY,, GeometricMeanParams memory params) =
        abi.decode(data, (uint256, uint256, int256, (GeometricMeanParams)));
    return computeTradingFunction({ rX: rX, rY: rY, L: L, params: params });
}

function computeNextLiquidity(
    uint256 rX,
    uint256 rY,
    int256 invariant,
    uint256 approximatedL,
    GeometricMeanParams memory params
) pure returns (uint256 L) {
    uint256 upper = approximatedL;
    uint256 lower = approximatedL;
    int256 computedInvariant = invariant;
    if (computedInvariant < 0) {
        while (computedInvariant < 0) {
            lower = lower.mulDivDown(999, 1000);
            computedInvariant = computeTradingFunction({
                rX: rX,
                rY: rY,
                L: lower,
                params: params
            });
        }
    } else {
        while (computedInvariant > 0) {
            upper = upper.mulDivUp(1001, 1000);
            computedInvariant = computeTradingFunction({
                rX: rX,
                rY: rY,
                L: upper,
                params: params
            });
        }
    }
    (uint256 rootInput,, uint256 lowerInput) = bisection(
        abi.encode(rX, rY, computedInvariant, params),
        lower,
        upper,
        uint256(1),
        256,
        findRootLiquidity
    );

    if (computeTradingFunction(rX, rY, rootInput, params) == 0) {
        L = rootInput;
    } else {
        L = lowerInput;
    }
}

function computeInitialPoolData(
    uint256 amountX,
    uint256 initialPrice,
    GeometricMeanParams memory params
) pure returns (bytes memory) {
    uint256 rY = computeY(amountX, initialPrice, params);
    uint256 L = computeL(amountX, rY, params);

    int256 invariant =
        computeTradingFunction({ rX: amountX, rY: rY, L: L, params: params });

    L = computeNextLiquidity(amountX, rY, invariant, L, params);

    uint256[] memory reserves = new uint256[](2);
    reserves[0] = amountX;
    reserves[1] = rY;

    return abi.encode(reserves, L, params.wX, params.swapFee, params.controller);
}

function computeSwapDeltaLiquidity(
    uint256 amountIn,
    uint256 reserve,
    uint256 totalLiquidity,
    uint256 weight,
    uint256 swapFee
) pure returns (uint256) {
    return weight.mulWadUp(swapFee).mulWadUp(totalLiquidity).mulWadUp(
        amountIn.divWadUp(reserve)
    );
}
