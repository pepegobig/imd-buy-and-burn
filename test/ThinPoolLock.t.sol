// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The swarm audit's proof for its medium finding (IMD job de9e10c6, finding 1), with preview() updated to the new
// return values. It failed on commit 4e49d40: a flat but thin WETH/IMD pair made every $1,000 burn revert.

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

contract ThinPoolLockTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant PAIR_A = 0x88A43bbDF9D098eEC7bCEda4e2494615dfD9bB9C; // USDC/WETH
    address constant PAIR_B = 0xDE66c35e01ED8e619Bf092352338ef94f2327337; // WETH/IMD
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IMDBuyAndBurn burner;

    function setUp() public {
        vm.warp(1_760_000_000);
        address tok = address(new MockToken());
        vm.etch(USDC, tok.code);
        vm.etch(WETH, tok.code);
        vm.etch(IMD, tok.code);
        address pair = address(new MockPair());
        vm.etch(PAIR_A, pair.code);
        vm.etch(PAIR_B, pair.code);
        // Same token order as on Base: WETH is token0 of both pairs
        MockToken(WETH).mint(PAIR_A, 180e18);
        MockToken(USDC).mint(PAIR_A, 436_000e6);
        MockPair(PAIR_A).init(WETH, USDC);
        MockToken(WETH).mint(PAIR_B, 16.5e18);
        MockToken(IMD).mint(PAIR_B, 6_600e18);
        MockPair(PAIR_B).init(WETH, IMD);
        burner = new IMDBuyAndBurn();
    }

    function test_FlatPriceBalanceOver1000CanBeBurned() public {
        MockToken(USDC).mint(address(burner), 1_000e6);
        vm.warp(block.timestamp + 31 minutes);
        (uint256 usdcIn, uint256 twapOut, uint256 spotOut,,) = burner.preview();
        emit log_named_uint("spot/twap bps (no price move)", (spotOut * 10_000) / twapOut);
        emit log_named_decimal_uint("USDC spent by this burn (depth cap)", usdcIn, 6);

        uint256 deadBefore = MockToken(IMD).balanceOf(DEAD);
        burner.buyAndBurn();
        assertGt(MockToken(IMD).balanceOf(DEAD), deadBefore, "IMD burned");
        assertLt(MockToken(USDC).balanceOf(address(burner)), 1_000e6, "USDC spent");
    }

    /// The thin pool drains over several windows instead of locking
    function test_ThinPoolDrainsOverSeveralBurns() public {
        MockToken(USDC).mint(address(burner), 1_000e6);
        for (uint256 i = 0; i < 40 && MockToken(USDC).balanceOf(address(burner)) >= 5e6; i++) {
            vm.warp(block.timestamp + 31 minutes);
            burner.buyAndBurn();
        }
        assertEq(MockToken(USDC).balanceOf(address(burner)), 0, "all burned, no dust");
    }
}
