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
        (uint256 usdcIn, uint256 twapOut, uint256 spotOut, uint256 poolOut,) = burner.preview();
        assertEq(usdcIn, 10e6);
        assertApproxEqRel(spotOut, twapOut, 1e15, "no trades: spot equals the TWAP");
        uint256 burned = burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 0, "all USDC spent");
        assertEq(IERC20(FP).balanceOf(DEAD) - deadBefore, burned, "burn reached 0xdead");
        assertEq(burned, poolOut, "0xdead is exempt from the FP buy fee today");
        assertGe(poolOut, (spotOut * 99) / 100, "fees and impact under 1% at $10");
        assertEq(burner.totalUsdcSpent(), 10e6);
        assertEq(burner.totalImdBurned(), burned);
        emit log_named_decimal_uint("IMD (FP) burned for $10", burned, 18);
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

    function test_CapsOneBurn() public {
        _fund(1_500e6);
        _wait(31 minutes);
        (uint256 usdcIn,,,,) = burner.preview();
        assertLe(usdcIn, 1_000e6, "never more than MAX_PER_BURN");
        burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 1_500e6 - usdcIn, "the rest waits for the next burn");
        assertGe(IERC20(USDC).balanceOf(address(burner)), 500e6);
    }

    function test_AtomicPumpReverts() public {
        _fund(10e6);
        _wait(31 minutes);
        // An attacker pushes the IMD price up in the same block as the burn (the first leg of a sandwich)
        _pumpImd(8); // about 12% of the WETH side
        vm.expectRevert(); // PriceOffTwap(twapOut, spotOut)
        burner.buyAndBurn();
    }

    function test_PokeOnlyWhenStale() public {
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.NotStale.selector, uint32(0)));
        burner.poke();
        uint32 obs = burner.obsTime();
        _wait(6 hours + 1);
        burner.poke();
        assertEq(burner.pendTime(), uint32(block.timestamp), "pending window opened");
        assertEq(burner.obsTime(), obs, "the burn window is unchanged");
        vm.expectRevert(abi.encodeWithSelector(IMDBuyAndBurn.PendingWindow.selector, uint32(0)));
        burner.poke();
    }

    /// Audit de9e10c6 finding 4 and dca64686 finding 1: poke() must not delay a burn that would succeed
    function test_PokeCannotDelayAValidBurn() public {
        _fund(10e6);
        _wait(6 hours + 1);
        burner.poke();
        assertGt(burner.buyAndBurn(), 0);
        assertEq(burner.pendTime(), 0, "a burn closes the pending window");
    }

    /// After a real price move, a burn waits; poke() then starts a window at the new price
    function test_PokeRestartsTheWindowAfterAPriceMove() public {
        _fund(10e6);
        _wait(6 hours + 1);
        _pumpImd(8); // IMD about 25% dearer, and it stays there
        vm.expectRevert();
        burner.buyAndBurn(); // PriceOffTwap
        burner.poke();
        _wait(31 minutes);
        assertGt(burner.buyAndBurn(), 0);
    }

    /// Audit de9e10c6 finding 6 and dca64686 finding 2: a capped burn leaves a burnable remainder, never dust
    function test_CappedBurnLeavesABurnableRemainder() public {
        _wait(31 minutes);
        (uint256 cap,,,,) = _previewFor(10_000e6);
        _fund(cap + 4e6);
        burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 5e6, "exactly THRESHOLD is left");
        _wait(31 minutes);
        burner.buyAndBurn();
        assertEq(IERC20(USDC).balanceOf(address(burner)), 0);
    }

    /// preview() for a balance, without keeping that balance
    function _previewFor(uint256 amount) internal returns (uint256, uint256, uint256, uint256, uint32) {
        uint256 snap = vm.snapshotState();
        _fund(amount);
        (uint256 a, uint256 b, uint256 c, uint256 d, uint32 e) = burner.preview();
        vm.revertToState(snap);
        return (a, b, c, d, e);
    }

    /// Audit finding 3: if FP's owner removes 0xdead's fee exemption, burns still run and the event shows the loss
    function test_FeeExemptionRemovedStillBurns() public {
        _fund(100e6);
        _wait(31 minutes);
        (bool ok,) = FP.call(abi.encodeWithSignature("owner()"));
        assertTrue(ok);
        address fpOwner = abi.decode(_call(FP, abi.encodeWithSignature("owner()")), (address));
        vm.prank(fpOwner);
        (ok,) = FP.call(abi.encodeWithSignature("excludeFromFees(address,bool)", DEAD, false));
        assertTrue(ok, "excludeFromFees");
        (,,, uint256 poolOut,) = burner.preview();
        uint256 burned = burner.buyAndBurn();
        assertLt(burned, poolOut, "the FP buy fee is taken");
        assertGe(burned, (poolOut * 95) / 100, "at most 5% (FP's fee cap)");
    }

    function _call(address to, bytes memory data) internal view returns (bytes memory out) {
        bool ok;
        (ok, out) = to.staticcall(data);
        require(ok, "call");
    }

    /// Buys IMD with 1/divisor of the WETH/IMD pair's WETH reserve and sends it to 0xdead
    function _pumpImd(uint256 divisor) internal {
        IUniswapV2Pair pair = burner.WETH_IMD();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool wethIs0 = pair.token0() == WETH;
        (uint256 rW, uint256 rI) = wethIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 wethIn = rW / divisor;
        address trader = makeAddr("trader");
        deal(WETH, trader, wethIn);
        uint256 out = _amountOut(wethIn, rW, rI);
        vm.startPrank(trader);
        IERC20(WETH).transfer(address(pair), wethIn);
        if (wethIs0) pair.swap(0, out, DEAD, "");
        else pair.swap(out, 0, DEAD, "");
        vm.stopPrank();
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
