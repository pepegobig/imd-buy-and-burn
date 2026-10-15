// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDBuyAndBurn, IUniswapV2Pair, IERC20} from "../src/IMDBuyAndBurn.sol";

/// Runs against a fork of Base mainnet: BASE_RPC=<url> forge test (default: the public node)
contract IMDBuyAndBurnTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant FP = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IMDBuyAndBurn burner;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://base-rpc.publicnode.com")));
        burner = new IMDBuyAndBurn();
    }

    function _fund(uint256 amount) internal {
        deal(USDC, address(burner), IERC20(USDC).balanceOf(address(burner)) + amount);
    }

    function _wait(uint256 s) internal {
        vm.warp(block.timestamp + s);
        vm.roll(block.number + s / 2);
    }

    function _amountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    function test_RevertsBelowThreshold() public {
        _fund(4_999_999);
        _wait(31 minutes);
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.BelowThreshold.selector, 4_999_999));
        burner.buyAndBurn();
    }

    function test_RevertsInsideWindow() public {
        _fund(10e6);
        _wait(10 minutes);
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.WindowTooShort.selector, uint32(10 minutes)));
        burner.buyAndBurn();
    }

    function test_BurnsTheUsdc() public {
        _fund(10e6);
        _wait(31 minutes);
        uint256 deadBefore = IERC20(FP).balanceOf(DEAD);
        (uint256 usdcIn, uint256 expected, uint256 spot,) = burner.preview();
        assertEq(usdcIn, 10e6);
        uint256 burned = burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 0, "all USDC spent");
        assertEq(IERC20(FP).balanceOf(DEAD) - deadBefore, burned, "burn reached 0xdead");
        assertGt(burned, 0);
        assertLe(burned, spot, "never more than the pool output");
        assertGe(burned, (spot * 95) / 100, "at most the 4% FP buy fee is lost");
        assertGe(spot, (expected * 97) / 100, "spot within 3% of TWAP");
        assertEq(burner.totalUsdcSpent(), 10e6);
        assertEq(burner.totalImdBurned(), burned);
        emit log_named_decimal_uint("IMD (FP) burned for $10", burned, 18);
        emit log_named_decimal_uint("pool output before the FP buy fee", spot, 18);
    }

    function test_SecondBurnNeedsANewWindow() public {
        _fund(10e6);
        _wait(31 minutes);
        burner.buyAndBurn();
        _fund(10e6);
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.WindowTooShort.selector, uint32(0)));
        burner.buyAndBurn();
        _wait(31 minutes);
        burner.buyAndBurn();
        assertEq(burner.totalUsdcSpent(), 20e6);
    }

    function test_CapsOneBurnAt1000() public {
        _fund(1_500e6);
        _wait(31 minutes);
        burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 500e6, "the rest waits for the next burn");
    }

    function test_AtomicPumpReverts() public {
        _fund(10e6);
        _wait(31 minutes);
        // An attacker pushes the IMD price up in the same block as the burn (the first leg of a sandwich)
        IUniswapV2Pair pair = burner.WETH_IMD();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool wethIs0 = pair.token0() == WETH;
        (uint256 rW, uint256 rI) = wethIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 wethIn = rW / 8; // about 12% of the WETH side
        address attacker = makeAddr("attacker");
        deal(WETH, attacker, wethIn);
        uint256 out = _amountOut(wethIn, rW, rI);
        vm.startPrank(attacker);
        IERC20(WETH).transfer(address(pair), wethIn);
        if (wethIs0) pair.swap(0, out, DEAD, "");
        else pair.swap(out, 0, DEAD, "");
        vm.stopPrank();
        vm.expectRevert(); // PriceOffTwap(expected, actual)
        burner.buyAndBurn();
    }

    function test_PokeOnlyWhenStale() public {
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.NotStale.selector, uint32(0)));
        burner.poke();
        _wait(6 hours + 1);
        burner.poke();
        assertEq(burner.obsTime(), uint32(block.timestamp));
    }

    function test_BurnsAfterLongIdle() public {
        _fund(10e6);
        _wait(3 days);
        assertGt(burner.buyAndBurn(), 0);
    }

    function test_BurnHeldSendsImdToDead() public {
        deal(FP, address(burner), 1e18);
        uint256 deadBefore = IERC20(FP).balanceOf(DEAD);
        assertEq(burner.burnHeld(), 1e18);
        assertEq(IERC20(FP).balanceOf(address(burner)), 0);
        assertEq(IERC20(FP).balanceOf(DEAD) - deadBefore, 1e18);
    }

    function test_RejectsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(burner).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
