// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "./GeometricMeanLib.sol";
import "src/interfaces/IStrategy.sol";
import "src/lib/DynamicParamLib.sol";
import "./G3MExtendedLib.sol";

/// @dev Parameterization of the GeometricMean curve.
struct GeometricMeanParams {
    uint256 wX;
    uint256 wY;
    uint256 swapFee;
    address controller;
}

/**
 * @notice Geometric Mean Market Maker.
 */
contract GeometricMean is IStrategy {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;
    using DynamicParamLib for DynamicParam;

    struct InternalParams {
        DynamicParam wX;
        uint256 swapFee;
        address controller;
    }

    /// @inheritdoc IStrategy
    address public immutable dfmm;

    /// @inheritdoc IStrategy
    string public constant name = "GeometricMean";

    mapping(uint256 => InternalParams) public internalParams;

    /// @param dfmm_ Address of the DFMM contract.
    constructor(address dfmm_) {
        dfmm = dfmm_;
    }

    // TODO: Move these errors into an interface
    error InvalidWeightX();

    /// @dev Restricts the caller to the DFMM contract.
    modifier onlyDFMM() {
        if (msg.sender != address(dfmm)) revert NotDFMM();
        _;
    }

    /// @inheritdoc IStrategy
    function init(
        address,
        uint256 poolId,
        IDFMM.Pool calldata pool,
        bytes calldata data
    )
        external
        onlyDFMM
        returns (
            bool valid,
            int256 invariant,
            uint256 reserveX,
            uint256 reserveY,
            uint256 totalLiquidity
        )
    {
        (valid, invariant, reserveX, reserveY, totalLiquidity,,,) =
            _decodeInit(poolId, data);
    }

    function _decodeInit(
        uint256 poolId,
        bytes calldata data
    )
        private
        returns (
            bool valid,
            int256 invariant,
            uint256 reserveX,
            uint256 reserveY,
            uint256 totalLiquidity,
            uint256 wX,
            uint256 swapFee,
            address controller
        )
    {
        (reserveX, reserveY, totalLiquidity, wX, swapFee, controller) = abi
            .decode(data, (uint256, uint256, uint256, uint256, uint256, address));

        if (wX >= ONE) {
            revert InvalidWeightX();
        }

        internalParams[poolId].wX.lastComputedValue = wX;
        internalParams[poolId].swapFee = swapFee;
        internalParams[poolId].controller = controller;

        invariant = GeometricMeanLib.tradingFunction(
            reserveX,
            reserveY,
            totalLiquidity,
            abi.decode(getPoolParams(poolId), (GeometricMeanParams))
        );

        // todo: should the be EXACTLY 0? just positive? within an epsilon?
        valid = -(EPSILON) < invariant && invariant < EPSILON;
    }

    error DeltaError(uint256 expected, uint256 actual);

    /// @inheritdoc IStrategy
    function validateAllocate(
        address,
        uint256 poolId,
        IDFMM.Pool calldata pool,
        bytes calldata data
    )
        external
        view
        returns (
            bool valid,
            int256 invariant,
            uint256 deltaX,
            uint256 deltaY,
            uint256 deltaLiquidity
        )
    {
        (uint256 maxDeltaX, uint256 maxDeltaY, uint256 deltaL) =
            abi.decode(data, (uint256, uint256, uint256));

        // TODO: This is a small trick because `deltaLiquidity` cannot be used
        // directly, let's fix this later.
        deltaLiquidity = deltaL;

        deltaX =
            computeDeltaXGivenDeltaL(deltaL, pool.totalLiquidity, pool.reserveX);
        deltaY = computeDeltaYGivenDeltaX(deltaX, pool.reserveX, pool.reserveY);

        if (deltaX > maxDeltaX) {
            revert DeltaError(maxDeltaX, deltaX);
        }

        if (deltaY > maxDeltaY) {
            revert DeltaError(maxDeltaY, deltaY);
        }

        uint256 poolId = poolId;

        invariant = GeometricMeanLib.tradingFunction(
            pool.reserveX + deltaX,
            pool.reserveY + deltaY,
            pool.totalLiquidity + deltaLiquidity,
            abi.decode(getPoolParams(poolId), (GeometricMeanParams))
        );

        valid = -(EPSILON) < invariant && invariant < EPSILON;
    }

    /// @inheritdoc IStrategy
    function validateDeallocate(
        address,
        uint256 poolId,
        IDFMM.Pool calldata pool,
        bytes calldata data
    )
        external
        view
        returns (
            bool valid,
            int256 invariant,
            uint256 deltaX,
            uint256 deltaY,
            uint256 deltaLiquidity
        )
    {
        (uint256 minDeltaX, uint256 minDeltaY, uint256 deltaL) =
            abi.decode(data, (uint256, uint256, uint256));
        deltaLiquidity = deltaL;

        deltaX =
            computeDeltaXGivenDeltaL(deltaL, pool.totalLiquidity, pool.reserveX);
        deltaY = computeDeltaYGivenDeltaX(deltaX, pool.reserveX, pool.reserveY);

        if (minDeltaX > deltaX) {
            revert DeltaError(minDeltaX, deltaX);
        }

        if (minDeltaY > deltaY) {
            revert DeltaError(minDeltaY, deltaY);
        }

        uint256 poolId = poolId;

        invariant = GeometricMeanLib.tradingFunction(
            pool.reserveX - deltaX,
            pool.reserveY - deltaY,
            pool.totalLiquidity - deltaLiquidity,
            abi.decode(getPoolParams(poolId), (GeometricMeanParams))
        );

        valid = -(EPSILON) < invariant && invariant < EPSILON;
    }

    /// @inheritdoc IStrategy
    function validateSwap(
        address,
        uint256 poolId,
        IDFMM.Pool calldata pool,
        bytes memory data
    )
        external
        view
        returns (
            bool valid,
            int256 invariant,
            uint256 deltaX,
            uint256 deltaY,
            uint256 deltaLiquidity,
            bool isSwapXForY
        )
    {
        GeometricMeanParams memory params =
            abi.decode(getPoolParams(poolId), (GeometricMeanParams));

        (deltaX, deltaY, isSwapXForY) =
            abi.decode(data, (uint256, uint256, bool));

        if (isSwapXForY) {
            uint256 fees = deltaX.mulWadUp(params.swapFee);
            deltaLiquidity = fees.mulWadUp(pool.totalLiquidity).divWadUp(
                pool.reserveX
            ).mulWadUp(params.wX);
            invariant = GeometricMeanLib.tradingFunction(
                pool.reserveX + deltaX,
                pool.reserveY - deltaY,
                pool.totalLiquidity + deltaLiquidity,
                params
            );
        } else {
            uint256 fees = deltaY.mulWadUp(params.swapFee);
            deltaLiquidity = fees.mulWadUp(pool.totalLiquidity).divWadUp(
                pool.reserveY
            ).mulWadUp(params.wY);
            invariant = GeometricMeanLib.tradingFunction(
                pool.reserveX - deltaX,
                pool.reserveY + deltaY,
                pool.totalLiquidity + deltaLiquidity,
                params
            );
        }

        valid = -(EPSILON) < invariant && invariant < EPSILON;
    }

    /// @inheritdoc IStrategy
    function update(
        address sender,
        uint256 poolId,
        IDFMM.Pool calldata pool,
        bytes calldata data
    ) external onlyDFMM {
        if (sender != internalParams[poolId].controller) revert InvalidSender();
        GeometricMeanLib.GeometricMeanUpdateCode updateCode =
            abi.decode(data, (GeometricMeanLib.GeometricMeanUpdateCode));

        if (updateCode == GeometricMeanLib.GeometricMeanUpdateCode.SwapFee) {
            internalParams[poolId].swapFee =
                GeometricMeanLib.decodeFeeUpdate(data);
        } else if (
            updateCode == GeometricMeanLib.GeometricMeanUpdateCode.WeightX
        ) {
            (uint256 targetWeightX, uint256 targetTimestamp) =
                GeometricMeanLib.decodeWeightXUpdate(data);
            internalParams[poolId].wX.set(targetWeightX, targetTimestamp);
        } else if (
            updateCode == GeometricMeanLib.GeometricMeanUpdateCode.Controller
        ) {
            internalParams[poolId].controller =
                GeometricMeanLib.decodeControllerUpdate(data);
        } else {
            revert InvalidUpdateCode();
        }
    }

    /// @inheritdoc IStrategy
    function getPoolParams(uint256 poolId) public view returns (bytes memory) {
        GeometricMeanParams memory params;

        params.wX = internalParams[poolId].wX.actualized();
        params.wY = ONE - params.wX;
        params.swapFee = internalParams[poolId].swapFee;
        params.controller = internalParams[poolId].controller;

        return abi.encode(params);
    }

    /// @inheritdoc IStrategy
    function computeSwapConstant(
        uint256 poolId,
        bytes memory data
    ) external view returns (int256) {
        (uint256 rx, uint256 ry, uint256 L) =
            abi.decode(data, (uint256, uint256, uint256));
        return GeometricMeanLib.tradingFunction(
            rx, ry, L, abi.decode(getPoolParams(poolId), (GeometricMeanParams))
        );
    }
}
