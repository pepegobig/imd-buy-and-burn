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
/// @dev Price safety: each burn checks the pools' current output against their time-weighted average price (TWAP)
/// since the previous burn (at least MIN_WINDOW ago). A pool moved inside the burn transaction (an atomic sandwich)
/// makes the output fall short of the TWAP and the burn reverts.
contract IMDBuyAndBurn {
    IERC20 public constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    IERC20 public constant IMD = IERC20(0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105); // Fren Pet, IMD on Base
    IUniswapV2Pair public constant USDC_WETH = IUniswapV2Pair(0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C);
    IUniswapV2Pair public constant WETH_IMD = IUniswapV2Pair(0xDE66c35e01ED8e619Bf092352338ef94f2327337);
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant THRESHOLD = 5e6; // $5 of USDC (6 decimals)
    uint256 public constant MAX_PER_BURN = 1_000e6; // larger balances burn in several calls (keeps price impact under 1%)
    uint256 public constant MAX_SHORTFALL_BPS = 300; // output may be at most 3% below the TWAP (covers 2 x 0.3% fees)
    uint32 public constant MIN_WINDOW = 30 minutes;
    uint32 public constant STALE_AFTER = 6 hours;

    /// @dev true when the input token of the hop is token0 of its pair
    bool private immutable usdcIsToken0;
    bool private immutable wethIsToken0;

    /// @notice Cumulative prices (input token priced in output token, UQ112x112) at the last observation
    uint256 public obsUsdcWeth;
    uint256 public obsWethImd;
    uint32 public obsTime;

    uint256 public totalUsdcSpent;
    uint256 public totalImdBurned;

    event Burned(address indexed caller, uint256 usdcIn, uint256 wethOut, uint256 imdBurned);
    event Observed(uint32 time);

    error BelowThreshold(uint256 balance);
    error WindowTooShort(uint32 elapsed);
    error NotStale(uint32 elapsed);
    error PriceOffTwap(uint256 expected, uint256 actual);
    error BadPair();

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

    /// @notice Spends the contract's USDC (up to MAX_PER_BURN) on IMD and burns it. Anyone may call it once the
    /// balance is at least THRESHOLD and MIN_WINDOW has passed since the last observation.
    function buyAndBurn() external returns (uint256 burned) {
        uint256 balance = USDC.balanceOf(address(this));
        if (balance < THRESHOLD) revert BelowThreshold(balance);
        uint32 elapsed;
        unchecked {
            elapsed = uint32(block.timestamp) - obsTime;
        }
        if (elapsed < MIN_WINDOW) revert WindowTooShort(elapsed);

        uint256 usdcIn = balance > MAX_PER_BURN ? MAX_PER_BURN : balance;

        // Expected output at the TWAP since the last observation
        uint256 cumA = _cumulative(USDC_WETH, usdcIsToken0);
        uint256 cumB = _cumulative(WETH_IMD, wethIsToken0);
        uint256 avgA;
        uint256 avgB;
        unchecked {
            avgA = (cumA - obsUsdcWeth) / elapsed;
            avgB = (cumB - obsWethImd) / elapsed;
        }
        uint256 expectedImd = _mulQ112(_mulQ112(usdcIn, avgA), avgB);

        // Hop 1: USDC -> WETH, delivered straight to the second pair
        uint256 wethOut = _amountOut(USDC_WETH, usdcIsToken0, usdcIn);
        require(USDC.transfer(address(USDC_WETH), usdcIn), "USDC transfer");
        if (usdcIsToken0) USDC_WETH.swap(0, wethOut, address(WETH_IMD), "");
        else USDC_WETH.swap(wethOut, 0, address(WETH_IMD), "");

        // Hop 2: WETH -> IMD, delivered straight to 0x...dEaD (FP exempts transfers to it from its size limits)
        uint256 imdOut = _amountOut(WETH_IMD, wethIsToken0, wethOut);
        if (imdOut < (expectedImd * (10_000 - MAX_SHORTFALL_BPS)) / 10_000) revert PriceOffTwap(expectedImd, imdOut);
        uint256 deadBefore = IMD.balanceOf(DEAD);
        if (wethIsToken0) WETH_IMD.swap(0, imdOut, DEAD, "");
        else WETH_IMD.swap(imdOut, 0, DEAD, "");
        burned = IMD.balanceOf(DEAD) - deadBefore; // FP takes a buy fee, so this can be below imdOut

        obsUsdcWeth = cumA;
        obsWethImd = cumB;
        obsTime = uint32(block.timestamp);
        totalUsdcSpent += usdcIn;
        totalImdBurned += burned;
        emit Burned(msg.sender, usdcIn, wethOut, burned);
    }

    /// @notice Starts a fresh TWAP window when the last observation is older than STALE_AFTER, so a long price trend
    /// cannot block burns. It cannot be used to hold burns back: a fresh window can only start after a stale one.
    function poke() external {
        uint32 elapsed;
        unchecked {
            elapsed = uint32(block.timestamp) - obsTime;
        }
        if (elapsed <= STALE_AFTER) revert NotStale(elapsed);
        _observe();
    }

    /// @notice Burns any IMD (FP) sent to this contract directly.
    function burnHeld() external returns (uint256 amount) {
        amount = IMD.balanceOf(address(this));
        if (amount > 0) {
            require(IMD.transfer(DEAD, amount), "IMD transfer");
            totalImdBurned += amount;
            emit Burned(msg.sender, 0, 0, amount);
        }
    }

    /// @notice What a burn would spend now and the IMD it expects at the TWAP (zero inside the first MIN_WINDOW)
    function preview() external view returns (uint256 usdcIn, uint256 expectedImd, uint256 spotImd, uint32 elapsed) {
        uint256 balance = USDC.balanceOf(address(this));
        usdcIn = balance > MAX_PER_BURN ? MAX_PER_BURN : balance;
        unchecked {
            elapsed = uint32(block.timestamp) - obsTime;
        }
        if (elapsed > 0) {
            uint256 avgA;
            uint256 avgB;
            unchecked {
                avgA = (_cumulative(USDC_WETH, usdcIsToken0) - obsUsdcWeth) / elapsed;
                avgB = (_cumulative(WETH_IMD, wethIsToken0) - obsWethImd) / elapsed;
            }
            expectedImd = _mulQ112(_mulQ112(usdcIn, avgA), avgB);
        }
        if (usdcIn > 0) spotImd = _amountOut(WETH_IMD, wethIsToken0, _amountOut(USDC_WETH, usdcIsToken0, usdcIn));
    }

    function _observe() private {
        obsUsdcWeth = _cumulative(USDC_WETH, usdcIsToken0);
        obsWethImd = _cumulative(WETH_IMD, wethIsToken0);
        obsTime = uint32(block.timestamp);
        emit Observed(obsTime);
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
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = inIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    /// @dev amount * price (UQ112x112), rounded down; reverts on overflow (amounts are capped by MAX_PER_BURN)
    function _mulQ112(uint256 amount, uint256 priceQ112) private pure returns (uint256) {
        return (amount * priceQ112) >> 112;
    }
}
