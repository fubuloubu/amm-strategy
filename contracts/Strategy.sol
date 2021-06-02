// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

interface IERC20Extended {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

interface AMMPool is IERC20 {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves() external view returns (uint256 reserveA, uint256 reserveB);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

contract AMMStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public other;
    AMMPool public pool;
    AMMStrategy public partner;

    bool public wantIsToken0;

    constructor(address _vault, address _pool, address _partner) public BaseStrategy(_vault) {
        pool = AMMPool(_pool);
        partner = AMMStrategy(_partner);

        // Check to make sure we don't end up in a bad position with our partner
        address _want = address(want);
        address _other = partner.want();
        require(_want != _other);
        other = IERC20(_other);

        address token0 = pool.token0();
        address token1 = pool.token1();
        require(_want == token0 || _want == token1);
        require(_other == token0 || _other == token1);

        if (_want == token0) {
            wantIsToken0 = true;
        } // else `wantIsToken0 = false` from empty value

        // We trust our partners! (for `provideAndSplit` and `negotiateLiquidation`)
        other.safeApprove(address(partner), uint256(-1));
        pool.safeApprove(address(partner), uint256(-1));
    }

    modifier onlyPartner() {
        require(msg.sender == address(partner));
        _;
    }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "AMMStrategy",
                    IERC20Extended(address(want)).symbol()
                    IERC20Extended(partner.want()).symbol()
                )
            );
    }

    function setPartner(address _partner) external onlyAuthorized {
        partner = AMMStrategy(_partner);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedLPTokenValueInWant() public view returns (uint256) {
        uint256 strategyTokens = pool.balanceOf(address(this));
        uint256 totalTokens = pool.totalSupply();
        (uint reserve0, uint reserve1,) = pool.getReserves();
        // `x * y = k` invariant implies the value of `EV[y]` in `X` tokens is equivalent to `EV[x]`
        // NOTE: This doesn't account for temporary slippage, should use an oracle for more important operations
        if (wantIsToken0) {
            return strategyTokens.mul(reserve0.mul(2)).div(totalTokens);
        } else {
            return strategyTokens.mul(reserve1.mul(2)).div(totalTokens);
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)).add(estimatedLPTokenValueInWant());
    }

    function rebalanceLiquidity()
        external
        onlyPartner
        returns (uint256 _benefitLiquidity)
    {
        // Assume partner and this contract each had half of the liquidity
        // Figure out Impermanent Loss benefit towards `want` (if any)
        // swap half of the IL benefit for `other`
        // send all `other` back
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        partner.rebalanceLiquidity();
        uint256 wantBalance = balanceOfWant();

        // Set profit or loss based on the initial debt
        if (_debtOutstanding <= wantBalance) {
            _profit = wantBalance - debt;
        } else {
            _loss = _debtOutstanding - wantBalance;
        }

        // Repay debt. Amount will depend if we had profit or loss
        if (_debtOutstanding > 0) {
            if (_profit >= 0) {
                _debtPayment = Math.min(
                    _debtOutstanding,
                    wantBalance.sub(_profit)
                );
            } else {
                _debtPayment = Math.min(
                    _debtOutstanding,
                    wantBalance.sub(_loss)
                );
            }
        }
    }

    function provideAndSplit(uint256 maxOther) onlyPartner external returns (uint256 halfLiquidity) {
        // Pull up to `maxOther` amount of `other` into this contract (based on amount of `want`)
        // Provide equal amount of `want` for `other` and add liquidity to AMM
        // Divide the new LP tokens into two
        // Send half the LP tokens back to `partner`, as well as any remaining `other`
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            partner.provideAndSplit(wantBalance.sub(_debtOutstanding));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        partner.rebalanceLiquidity();
        uint256 totalWant = want.balanceOf(address(this));

        // NOTE: Do this after rebalancing liquidity to make sure we're synchronized here
        if (_amountNeeded > totalWant) {
            pool.withdraw(_amountNeeded.sub(totalWant));
            totalWant = want.balanceOf(address(this));
        }

        if (_amountNeeded > totalWant) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function migratePartner(address _partner) onlyPartner external {
        partner = AMMStrategy(_partner);
    }

    function prepareMigration(address _newStrategy) internal override {
        other.transfer(_newStrategy, other.balanceOf(address(this));
        pool.transfer(_newStrategy, pool.balanceOf(address(this));
        partner.migratePartner(_newStrategy);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] tokens = [address(other), address(pool)];
    }
}
