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
/// impact) with its time-weighted average (TWAP) over the current window, which must be between MIN_WINDOW and
/// MAX_WINDOW old. If IMD is more than MAX_DEVIATION_BPS dearer than the TWAP (for example, moved by an atomic
/// sandwich), the burn reverts. A cheaper IMD passes: buying below the average is good for the burn. Fees and the trade's
/// own impact are not part of this check: they are bounded by size. One burn spends at most DEPTH_BPS of either pair's
/// input-side reserve, measured as the smaller of the reserve now and at the start of the window (so liquidity added
/// inside the burn's transaction cannot raise it), and at most MAX_PER_BURN. Two exceptions keep USDC from getting
/// stuck: a burn is never smaller than THRESHOLD, so a very thin pool still drains $5 a window, and a remainder under
/// THRESHOLD is spent with the last capped burn.
/// @dev Economics. Moving a v2 pair's price by d costs about 0.3% * d * reserve in round-trip fees; a burn of size S
/// loses at most about d * S to it. With S <= DEPTH_BPS = 0.1% of the reserve, a sandwich costs its author about three
/// times what the burn loses, unless the author has owned more than two thirds of the pair's liquidity since the window
/// began (and gets the fees back). On the WETH/FP pair FP's own 4% buy and sell fees make it costlier still. Near the
/// THRESHOLD floor (pools worth under about $10,000) a burn can reach 0.2% of a reserve, which halves that margin.
/// @dev Windows. The window starts at the last burn, at deployment, or at observe(). observe() restarts it only when it
/// is older than MAX_WINDOW, when no burn can run anyway, so it can never delay a burn.
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
    uint256 public constant MAX_PER_BURN = 1_000e6; // larger balances burn in several calls
    uint256 public constant DEPTH_BPS = 10; // one burn spends at most 0.1% of either pair's input-side reserve
    uint256 public constant MAX_DEVIATION_BPS = 300; // IMD may be at most 3% dearer at the margin than its TWAP
    uint32 public constant MIN_WINDOW = 30 minutes;
    uint32 public constant MAX_WINDOW = 2 hours;

    /// @dev true when the input token of the hop is token0 of its pair
    bool private immutable usdcIsToken0;
    bool private immutable wethIsToken0;

    /// @notice Cumulative prices (input token priced in output token, UQ112x112) at the start of the current window
    uint256 public obsUsdcWeth;
    uint256 public obsWethImd;
    uint32 public obsTime;
    /// @notice Reserves at the start of the current window (USDC and WETH of the USDC/WETH pair, WETH of the WETH/FP pair)
    uint112 public obsUsdc;
    uint112 public obsWethA;
    uint112 public obsWethB;

    uint256 public totalUsdcSpent;
    uint256 public totalImdBurned;

    /// @param imdBought what the pair sent; imdBurned what reached 0x...dEaD (lower only if FP charged its buy fee)
    event Burned(address indexed caller, uint256 usdcIn, uint256 wethOut, uint256 imdBought, uint256 imdBurned);
    event Observed(uint32 time);

    error BelowThreshold(uint256 balance);
    error WindowTooShort(uint32 elapsed);
    error WindowTooOld(uint32 elapsed);
    error WindowOpen(uint32 elapsed);
    error PriceOffTwap(uint256 twapOut, uint256 spotOut);
    error BadPair();

    /// @dev A burn as it would run in this block
    struct Quote {
        uint256 usdcIn;
        uint256 twapOut; // IMD for usdcIn at the TWAP, marginal (no fees, no impact)
        uint256 spotOut; // IMD for usdcIn at the current reserves, marginal
        uint256 cumA;
        uint256 cumB;
        uint256 cap; // the size bound: min(MAX_PER_BURN, DEPTH_BPS of either pair's input-side reserve, now and at obsTime)
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
        Quote memory q = _quote(balance);
        if (q.elapsed < MIN_WINDOW) revert WindowTooShort(q.elapsed);
        if (q.elapsed > MAX_WINDOW) revert WindowTooOld(q.elapsed);
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

        _observe();
        totalUsdcSpent += q.usdcIn;
        totalImdBurned += burned;
        emit Burned(msg.sender, q.usdcIn, wethOut, imdOut, burned);
    }

    /// @notice Starts a new TWAP window. Only allowed when the current one is older than MAX_WINDOW: then no burn can
    /// run, so this never delays one. A burn can follow MIN_WINDOW later.
    function observe() external {
        uint32 elapsed;
        unchecked {
            elapsed = uint32(block.timestamp) - obsTime;
        }
        if (elapsed <= MAX_WINDOW) revert WindowOpen(elapsed);
        _observe();
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
    /// (both marginal, before fees and impact), the IMD the pools would actually send, and the window length.
    function preview()
        external
        view
        returns (uint256 usdcIn, uint256 twapOut, uint256 spotOut, uint256 poolOut, uint32 elapsed)
    {
        Quote memory q = _quote(USDC.balanceOf(address(this)));
        usdcIn = q.usdcIn;
        twapOut = q.twapOut;
        spotOut = q.spotOut;
        elapsed = q.elapsed;
        if (usdcIn > 0) poolOut = _amountOut(WETH_IMD, wethIsToken0, _amountOut(USDC_WETH, usdcIsToken0, usdcIn));
    }

    function _withinTolerance(Quote memory q) private pure returns (bool) {
        return q.spotOut >= (q.twapOut * (10_000 - MAX_DEVIATION_BPS)) / 10_000;
    }

    /// @dev The burn this block would run, measured against the current window
    function _quote(uint256 balance) private view returns (Quote memory q) {
        unchecked {
            q.elapsed = uint32(block.timestamp) - obsTime;
        }
        (uint256 rUsdc, uint256 rWethA) = _reserves(USDC_WETH, usdcIsToken0);
        (uint256 rWethB, uint256 rImd) = _reserves(WETH_IMD, wethIsToken0);

        // Size: at most MAX_PER_BURN and DEPTH_BPS of the USDC reserve and of the WETH reserve (valued in USDC), each
        // taken as the smaller of now and the window's start
        uint256 cap = MAX_PER_BURN;
        uint256 depth = _depth(rUsdc, rWethA, rWethB);
        uint256 depthThen = _depth(obsUsdc, obsWethA, obsWethB);
        if (depthThen < depth) depth = depthThen;
        if (depth < cap) cap = depth;
        q.cap = cap;
        // Never smaller than THRESHOLD (a very thin pool still drains), and never leave a remainder under THRESHOLD
        uint256 size = cap > THRESHOLD ? cap : THRESHOLD;
        q.usdcIn = balance < size + THRESHOLD ? balance : size;

        q.cumA = _cumulative(USDC_WETH, usdcIsToken0);
        q.cumB = _cumulative(WETH_IMD, wethIsToken0);
        if (q.elapsed > 0) {
            uint256 avgA;
            uint256 avgB;
            unchecked {
                avgA = (q.cumA - obsUsdcWeth) / q.elapsed;
                avgB = (q.cumB - obsWethImd) / q.elapsed;
            }
            q.twapOut = _mulQ112(_mulQ112(q.usdcIn, avgA), avgB);
        }
        if (rUsdc != 0 && rWethB != 0) q.spotOut = (((q.usdcIn * rWethA) / rUsdc) * rImd) / rWethB;
    }

    function _observe() private {
        obsUsdcWeth = _cumulative(USDC_WETH, usdcIsToken0);
        obsWethImd = _cumulative(WETH_IMD, wethIsToken0);
        obsTime = uint32(block.timestamp);
        (uint256 rUsdc, uint256 rWethA) = _reserves(USDC_WETH, usdcIsToken0);
        (uint256 rWethB,) = _reserves(WETH_IMD, wethIsToken0);
        obsUsdc = uint112(rUsdc);
        obsWethA = uint112(rWethA);
        obsWethB = uint112(rWethB);
        emit Observed(obsTime);
    }

    /// @dev DEPTH_BPS of the USDC reserve and of the WETH/FP pair's WETH reserve valued in USDC, the smaller one
    function _depth(uint256 rUsdc, uint256 rWethA, uint256 rWethB) private pure returns (uint256) {
        uint256 depthA = (rUsdc * DEPTH_BPS) / 10_000;
        uint256 depthB = rWethA == 0 ? 0 : (((rWethB * DEPTH_BPS) / 10_000) * rUsdc) / rWethA;
        return depthA < depthB ? depthA : depthB;
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
