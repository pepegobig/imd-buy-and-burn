// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

/// Minimal Uniswap v2 pair: same reserves, cumulative-price and fee/K rules as UniswapV2Pair
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

// The swarm re-audit's proof for its finding 1 (IMD job dca64686): a pump, window restart, unwind bundle must not delay a
// valid burn. Adapted to the bounded window: observe() refuses to restart an open window, so the bundle cannot touch it.
contract PokeGriefTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant PAIR_A = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C; // USDC/WETH, WETH is token0
    address constant PAIR_B = 0xDE66c35e01ED8e619Bf092352338ef94f2327337; // WETH/IMD, WETH is token0

    IMDBuyAndBurn burner;

    function _deploy(uint256 wethB, uint256 imdB) internal {
        vm.warp(1_760_000_000);
        address tok = address(new MockToken());
        vm.etch(USDC, tok.code);
        vm.etch(WETH, tok.code);
        vm.etch(IMD, tok.code);
        address pair = address(new MockPair());
        vm.etch(PAIR_A, pair.code);
        vm.etch(PAIR_B, pair.code);
        // Pair A at its Base reserves (block 52644997): 179.7 WETH / 438,092 USDC
        MockToken(WETH).mint(PAIR_A, 179.7e18);
        MockToken(USDC).mint(PAIR_A, 438_092e6);
        MockPair(PAIR_A).init(WETH, USDC);
        MockToken(WETH).mint(PAIR_B, wethB);
        MockToken(IMD).mint(PAIR_B, imdB);
        MockPair(PAIR_B).init(WETH, IMD);
        burner = new IMDBuyAndBurn();
    }

    function _out(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    /// A bundle that pumps a pool, tries to restart the window and unwinds must not delay a valid burn
    function test_PumpPokeUnwindDelaysAValidBurn() public {
        _deploy(165.6e18, 66_004e18); // pair B at its Base reserves
        MockToken(USDC).mint(address(burner), 100e6);
        vm.warp(block.timestamp + 31 minutes);

        // One transaction (flash-swap sized): buy WETH from pair A to make it ~3.2% dearer, observe(), sell the WETH back
        address attacker = makeAddr("attacker");
        uint256 usdcIn = 7_000e6;
        MockToken(USDC).mint(attacker, usdcIn);
        vm.startPrank(attacker);
        (uint112 w, uint112 u,) = MockPair(PAIR_A).getReserves();
        uint256 wethOut = _out(usdcIn, u, w);
        MockToken(USDC).transfer(PAIR_A, usdcIn);
        MockPair(PAIR_A).swap(wethOut, 0, attacker, "");
        (bool poked,) = address(burner).call(abi.encodeCall(IMDBuyAndBurn.observe, ()));
        (w, u,) = MockPair(PAIR_A).getReserves();
        uint256 usdcBack = _out(wethOut, w, u);
        MockToken(WETH).transfer(PAIR_A, wethOut);
        MockPair(PAIR_A).swap(0, usdcBack, attacker, "");
        vm.stopPrank();
        emit log_named_decimal_uint("attacker cost (USDC)", usdcIn - usdcBack, 6);
        emit log_named_string("observe inside the bundle", poked ? "succeeded" : "reverted");

        // The pools are back where they were, so the burn that was available must still run
        burner.buyAndBurn();
    }

}
