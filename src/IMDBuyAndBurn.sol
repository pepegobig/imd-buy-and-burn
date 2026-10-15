// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title IMDBuyAndBurn
/// @notice Receives USDC on Base (for example Lobby payouts of the @imdpepe swarm account), buys IMD with it and burns it.
/// IMD on Base is Fren Pet (FP): the Ethereum IMD token is a LayerZero OFT whose Base peer locks FP.
/// Route: USDC -> WETH -> FP through two Uniswap v2 pairs; the second pair sends the FP straight to 0x...dEaD.
/// There is no owner and no withdraw function: USDC can only leave through buyAndBurn().
/// @dev Price safety. Before it trades, a burn compares the route's marginal price (both pairs' reserves, no fees, no
/// impact) with its time-weighted average (TWAP) since the last observation, at least MIN_WINDOW earlier. If IMD is more
/// than MAX_DEVIATION_BPS dearer than the TWAP (for example, moved by an atomic sandwich), the burn reverts. Fees and the
/// trade's own impact are not part of this check: they are bounded by size instead, since one burn spends at most
/// DEPTH_BPS of either pair's reserves and at most MAX_PER_BURN. DEPTH_BPS stays under the 0.3% round-trip fee of the
/// USDC/WETH pair, so a sandwich that stays inside the tolerance costs its author more in fees than it takes.
/// @dev Windows. A burn uses the window that starts at the last burn (or deployment). When that window is older than
/// STALE_AFTER, poke() opens a second, pending window; a burn may use either one, so poke() never delays a burn.
/// @dev Trust assumptions outside this contract (accepted, see README): Fren Pet's owner can blacklist 0x...dEaD, the
/// WETH/FP pair or this contract, which stops all burns and leaves the USDC here for good; the owner can also remove
/// 0x...dEaD's fee exemption, after which up to FP's buy fee (4% today) of each purchase goes to the FP contract instead
/// of 0x...dEaD (the Burned event reports it). Circle can blacklist this contract on USDC, or pause or upgrade USDC,
/// with the same effect.
contract IMDBuyAndBurn {
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    IERC20 public constant IMD = IERC20(0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105); // Fren Pet, IMD on Base
    IUniswapV2Pair public constant USDC_WETH = IUniswapV2Pair(0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C);
    IUniswapV2Pair public constant WETH_IMD = IUniswapV2Pair(0xDE66c35e01ED8e619Bf092352338ef94f2327337);
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant THRESHOLD = 5e6; // $5 of USDC (6 decimals)
    uint256 public constant MAX_PER_BURN = 1_000e6; // one burn never spends more; larger balances burn in several calls
    uint256 public constant DEPTH_BPS = 25; // one burn spends at most 0.25% of either pair's input-side reserve
    uint256 public constant MAX_DEVIATION_BPS = 300; // the route's marginal price may be at most 3% worse than the TWAP
    uint32 public constant MIN_WINDOW = 30 minutes;
    uint32 public constant STALE_AFTER = 6 hours;

    /// @dev true when the input token of the hop is token0 of its pair
    bool private immutable usdcIsToken0;
    bool private immutable wethIsToken0;

    /// @notice Cumulative prices (input token priced in output token, UQ112x112) at the last burn (or deployment)
    uint256 public obsUsdcWeth;
    uint256 public obsWethImd;
    uint32 public obsTime;
    /// @notice The pending window that poke() opened; pendTime 0 means none
    uint256 public pendUsdcWeth;
    uint256 public pendWethImd;
    uint32 public pendTime;

    uint256 public totalUsdcSpent;
    uint256 public totalImdBurned;

    /// @param imdBought what the pair sent; imdBurned what reached 0x...dEaD (lower only if FP charged its buy fee)
    event Burned(address indexed caller, uint256 usdcIn, uint256 wethOut, uint256 imdBought, uint256 imdBurned);
    event Observed(uint32 time);

    error BelowThreshold(uint256 balance);
    error WindowTooShort(uint32 elapsed);
    error NotStale(uint32 elapsed);
    error PendingWindow(uint32 elapsed);
    error PriceOffTwap(uint256 twapOut, uint256 spotOut);
    error BadPair();

    /// @dev A burn as it would run in this block
    struct Quote {
        uint256 usdcIn;
        uint256 twapOut; // IMD for usdcIn at the TWAP, marginal (no fees, no impact)
        uint256 spotOut; // IMD for usdcIn at the current reserves, marginal
        uint256 cumA;
        uint256 cumB;
        uint32 elapsed;
    }

    constructor() {
        address u0 = USDC_WETH.token0();
        address u1 = USDC_WETH.token1();
        address w0 = WETH_IMD.token0();
        address w1 = WETH_IMD.token1();
        if (!((u0 == address(USDC) && u1 == WETH) || (u0 == WETH && u1 == address(USDC)))) revert BadPair();
        if (!((w0 == WETH && w1 == address(IMD)) || (w0 == address(IMD) && w1 == WETH))) revert BadPair();
        usdcIsToken0 = u0 == address(USDC);
        wethIsToken0 = w0 == WETH;
        _observe();
    }

    /// @notice Spends the contract's USDC (bounded by MAX_PER_BURN and the pools' depth) on IMD and burns it. Anyone may
    /// call it once the balance is at least THRESHOLD and MIN_WINDOW has passed since the last observation.
    function buyAndBurn() external returns (uint256 burned) {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance < THRESHOLD) revert BelowThreshold(balance);
        Quote memory q = _quote(balance, obsUsdcWeth, obsWethImd, obsTime);
        if (!_ready(q) && pendTime != 0) {
            Quote memory p = _quote(balance, pendUsdcWeth, pendWethImd, pendTime);
            if (_ready(p)) q = p;
        }
        if (q.elapsed < MIN_WINDOW) revert WindowTooShort(q.elapsed);
        if (!_withinTolerance(q)) revert PriceOffTwap(q.twapOut, q.spotOut);

        // Hop 1: USDC -> WETH, delivered straight to the second pair
        uint256 wethOut = _amountOut(USDC_WETH, usdcIsToken0, q.usdcIn);
        require(USDC.transfer(address(USDC_WETH), q.usdcIn), "USDC transfer");
        if (usdcIsToken0) USDC_WETH.swap(0, wethOut, address(WETH_IMD), "");
        else USDC_WETH.swap(wethOut, 0, address(WETH_IMD), "");

        // Hop 2: WETH -> IMD, delivered straight to 0x...dEaD (FP exempts transfers to it from its size limits and,
        // today, from its buy fee)
        uint256 imdOut = _amountOut(WETH_IMD, wethIsToken0, wethOut);
        uint256 deadBefore = IMD.balanceOf(DEAD);
        if (wethIsToken0) WETH_IMD.swap(0, imdOut, DEAD, "");
        else WETH_IMD.swap(imdOut, 0, DEAD, "");
        burned = IMD.balanceOf(DEAD) - deadBefore;

        obsUsdcWeth = q.cumA;
        obsWethImd = q.cumB;
        obsTime = uint32(block.timestamp);
        pendTime = 0;
        totalUsdcSpent += q.usdcIn;
        totalImdBurned += burned;
        emit Burned(msg.sender, q.usdcIn, wethOut, imdOut, burned);
    }

    /// @notice Opens a pending TWAP window when the burn window is older than STALE_AFTER, so a long price trend cannot
    /// block burns for long: after MIN_WINDOW a burn may use the pending window instead. The burn window stays usable,
    /// so poke() cannot delay a burn. A pending window can only be replaced once it is older than STALE_AFTER itself.
    function poke() external {
        uint32 elapsed;
        uint32 pendElapsed;
        unchecked {
            elapsed = uint32(block.timestamp) - obsTime;
            pendElapsed = uint32(block.timestamp) - pendTime;
        }
        if (elapsed <= STALE_AFTER) revert NotStale(elapsed);
        if (pendTime != 0 && pendElapsed <= STALE_AFTER) revert PendingWindow(pendElapsed);
        pendUsdcWeth = _cumulative(USDC_WETH, usdcIsToken0);
        pendWethImd = _cumulative(WETH_IMD, wethIsToken0);
        pendTime = uint32(block.timestamp);
        emit Observed(pendTime);
    }

    /// @notice Burns any IMD (FP) sent to this contract directly.
    function burnHeld() external returns (uint256 amount) {
        amount = IMD.balanceOf(address(this));
        if (amount > 0) {
            require(IMD.transfer(DEAD, amount), "IMD transfer");
            totalImdBurned += amount;
            emit Burned(msg.sender, 0, 0, amount, amount);
        }
    }

    /// @notice What a burn would do now: the USDC it spends, the IMD it would get at the TWAP and at the current reserves
    /// (both marginal, before fees and impact), the IMD the pools would actually send, and the window length. It shows
    /// the burn window, or the pending window when only that one would pass.
    function preview()
        external
        view
        returns (uint256 usdcIn, uint256 twapOut, uint256 spotOut, uint256 poolOut, uint32 elapsed)
    {
        uint256 balance = USDC.balanceOf(address(this));
        Quote memory q = _quote(balance, obsUsdcWeth, obsWethImd, obsTime);
        if (!_ready(q) && pendTime != 0) {
            Quote memory p = _quote(balance, pendUsdcWeth, pendWethImd, pendTime);
            if (_ready(p)) q = p;
        }
        usdcIn = q.usdcIn;
        twapOut = q.twapOut;
        spotOut = q.spotOut;
        elapsed = q.elapsed;
        if (usdcIn > 0) poolOut = _amountOut(WETH_IMD, wethIsToken0, _amountOut(USDC_WETH, usdcIsToken0, usdcIn));
    }

    function _ready(Quote memory q) private pure returns (bool) {
        return q.elapsed >= MIN_WINDOW && _withinTolerance(q);
    }

    function _withinTolerance(Quote memory q) private pure returns (bool) {
        return q.spotOut >= (q.twapOut * (10_000 - MAX_DEVIATION_BPS)) / 10_000;
    }

    /// @dev The burn this block would run, measured against the window that starts at (refA, refB, refTime)
    function _quote(uint256 balance, uint256 refA, uint256 refB, uint32 refTime) private view returns (Quote memory q) {
        unchecked {
            q.elapsed = uint32(block.timestamp) - refTime;
        }
        (uint256 rUsdc, uint256 rWethA) = _reserves(USDC_WETH, usdcIsToken0);
        (uint256 rWethB, uint256 rImd) = _reserves(WETH_IMD, wethIsToken0);

        // Size: at most MAX_PER_BURN and DEPTH_BPS of the USDC reserve and of the WETH reserve (valued in USDC)
        uint256 cap = MAX_PER_BURN;
        uint256 depthA = (rUsdc * DEPTH_BPS) / 10_000;
        uint256 depthB = rWethA == 0 ? 0 : (((rWethB * DEPTH_BPS) / 10_000) * rUsdc) / rWethA;
        uint256 depth = depthA < depthB ? depthA : depthB;
        if (depth < cap) cap = depth;
        q.usdcIn = balance <= cap ? balance : cap;
        // A capped burn leaves at least THRESHOLD behind, so the remainder can always be burned in a later window
        if (q.usdcIn < balance && balance - q.usdcIn < THRESHOLD && balance > THRESHOLD) q.usdcIn = balance - THRESHOLD;

        q.cumA = _cumulative(USDC_WETH, usdcIsToken0);
        q.cumB = _cumulative(WETH_IMD, wethIsToken0);
        if (q.elapsed > 0) {
            uint256 avgA;
            uint256 avgB;
            unchecked {
                avgA = (q.cumA - refA) / q.elapsed;
                avgB = (q.cumB - refB) / q.elapsed;
            }
            q.twapOut = _mulQ112(_mulQ112(q.usdcIn, avgA), avgB);
        }
        if (rUsdc != 0 && rWethB != 0) q.spotOut = (((q.usdcIn * rWethA) / rUsdc) * rImd) / rWethB;
    }

    function _observe() private {
        obsUsdcWeth = _cumulative(USDC_WETH, usdcIsToken0);
        obsWethImd = _cumulative(WETH_IMD, wethIsToken0);
        obsTime = uint32(block.timestamp);
        emit Observed(obsTime);
    }

    /// @dev (input-token reserve, output-token reserve) of a hop
    function _reserves(IUniswapV2Pair pair, bool inIsToken0) private view returns (uint256 rIn, uint256 rOut) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rIn, rOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev The pair's cumulative price of the input token in output-token units, brought up to this block
    /// (Uniswap's UniswapV2OracleLibrary.currentCumulativePrices). Overflow is expected and wraps.
    function _cumulative(IUniswapV2Pair pair, bool inIsToken0) private view returns (uint256 c) {
        c = inIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        (uint112 r0, uint112 r1, uint32 last) = pair.getReserves();
        uint32 now32 = uint32(block.timestamp);
        if (last != now32 && r0 != 0 && r1 != 0) {
            unchecked {
                uint32 dt = now32 - last;
                c += inIsToken0 ? ((uint256(r1) << 112) / r0) * dt : ((uint256(r0) << 112) / r1) * dt;
            }
        }
    }

    /// @dev Uniswap v2 getAmountOut with the 0.3% fee
    function _amountOut(IUniswapV2Pair pair, bool inIsToken0, uint256 amountIn) private view returns (uint256) {
        (uint256 rIn, uint256 rOut) = _reserves(pair, inIsToken0);
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    /// @dev amount * price (UQ112x112), rounded down; reverts on overflow (amounts are capped by MAX_PER_BURN)
    function _mulQ112(uint256 amount, uint256 priceQ112) private pure returns (uint256) {
        return (amount * priceQ112) >> 112;
    }
}
